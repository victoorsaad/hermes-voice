import Foundation
import Security

/// Segredos (tokens do Notion e do Slack) no Keychain do usuário, nunca no config.json.
enum Keychain {
    private static let service = (Bundle.main.bundleIdentifier ?? "io.github.hermes-voice") + ".tokens"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        let s = String(decoding: data, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    /// Valor vazio apaga.
    static func set(_ account: String, _ value: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(v.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static let notionToken = "notion-token"
    static let slackWebhook = "slack-webhook"
    static let slackBotToken = "slack-bot-token"
}

/// HTTP síncrono com timeout: as notas são gravadas fora da thread principal, como o git do vault.
enum HTTP {
    static func json(_ method: String, _ url: String, headers: [String: String], body: Any? = nil) throws -> [String: Any] {
        guard let u = URL(string: url) else { throw HermesError("URL inválida: \(url)") }
        var req = URLRequest(url: u, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let sem = DispatchSemaphore(value: 0)
        var result: (Data?, URLResponse?, Error?)
        URLSession.shared.dataTask(with: req) { d, r, e in result = (d, r, e); sem.signal() }.resume()
        sem.wait()
        if let e = result.2 { throw e }
        let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        let data = result.0 ?? Data()
        guard (200..<300).contains(status) else {
            throw HermesError("\(u.host ?? "") respondeu \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

/// Nota da call como página num banco do Notion. Referência guardada em `notePath`: "notion:<id da página>".
/// Reescrever (refinar, nomear falantes, links) arquiva a página antiga e cria outra com o texto novo.
struct Notion {
    static let prefix = "notion:"
    private let token: String
    private let database: String

    init(config: Config) throws {
        guard let token = Keychain.get(Keychain.notionToken) else { throw HermesError("Token do Notion não configurado (Ajustes)") }
        let db = config.notionDatabaseID.trimmingCharacters(in: .whitespaces)
        guard !db.isEmpty else { throw HermesError("ID do banco do Notion não configurado (Ajustes)") }
        self.token = token
        self.database = Self.extractID(db)
    }

    private var headers: [String: String] { ["Authorization": "Bearer \(token)", "Notion-Version": "2022-06-28"] }
    private let api = "https://api.notion.com/v1"

    /// Aceita o ID puro ou o link do banco.
    static func extractID(_ s: String) -> String {
        let path = URL(string: s)?.path ?? s
        let last = (path as NSString).lastPathComponent
        let hex = last.split(separator: "-").last.map(String.init) ?? last
        return hex.count == 32 ? hex : s
    }

    static func url(_ ref: String) -> URL? {
        URL(string: "https://www.notion.so/" + ref.dropFirst(prefix.count).replacingOccurrences(of: "-", with: ""))
    }

    func write(_ t: CallTranscript, markdown: String) throws -> String {
        if let old = t.notePath, old.hasPrefix(Self.prefix) { try? archive(old) }
        let db = try HTTP.json("GET", "\(api)/databases/\(database)", headers: headers)
        let props = db["properties"] as? [String: [String: Any]] ?? [:]
        guard let titleProp = props.first(where: { $0.value["type"] as? String == "title" })?.key else {
            throw HermesError("O banco do Notion não tem coluna de título")
        }
        let blocks = Self.blocks(markdown)
        let page = try HTTP.json("POST", "\(api)/pages", headers: headers, body: [
            "parent": ["database_id": database],
            "properties": [titleProp: ["title": Self.text(t.title ?? "Call")]],
            "children": Array(blocks.prefix(100)),
        ])
        guard let id = page["id"] as? String else { throw HermesError("Notion não devolveu a página") }
        // A API aceita até 100 blocos por chamada.
        var rest = Array(blocks.dropFirst(100))
        while !rest.isEmpty {
            _ = try HTTP.json("PATCH", "\(api)/blocks/\(id)/children", headers: headers, body: ["children": Array(rest.prefix(100))])
            rest = Array(rest.dropFirst(100))
        }
        return Self.prefix + id
    }

    func archive(_ ref: String) throws {
        _ = try HTTP.json("PATCH", "\(api)/pages/\(ref.dropFirst(Self.prefix.count))", headers: headers, body: ["archived": true])
    }

    private static func text(_ s: String) -> [[String: Any]] {
        // Cada pedaço de texto tem limite de 2000 caracteres.
        var parts: [[String: Any]] = []
        var rest = Substring(s)
        while !rest.isEmpty {
            parts.append(["type": "text", "text": ["content": String(rest.prefix(1900))]])
            rest = rest.dropFirst(1900)
        }
        return parts
    }

    /// Markdown da nota → blocos simples (títulos, listas, tarefas, citações, parágrafos). O front matter fica de fora.
    static func blocks(_ md: String) -> [[String: Any]] {
        var lines = md.components(separatedBy: "\n")
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines.removeSubrange(0...end) }
        var out: [[String: Any]] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("# ") else { continue }
            let clean = { (s: String) in s.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
                .replacingOccurrences(of: "**", with: "") }
            func block(_ type: String, _ s: String, _ extra: [String: Any] = [:]) -> [String: Any] {
                var body: [String: Any] = ["rich_text": text(clean(s))]
                body.merge(extra) { a, _ in a }
                return ["object": "block", "type": type, type: body]
            }
            if line.hasPrefix("### ") { out.append(block("heading_3", String(line.dropFirst(4)))) }
            else if line.hasPrefix("## ") { out.append(block("heading_2", String(line.dropFirst(3)))) }
            else if line.hasPrefix("- [ ] ") { out.append(block("to_do", String(line.dropFirst(6)), ["checked": false])) }
            else if line.hasPrefix("- [x] ") { out.append(block("to_do", String(line.dropFirst(6)), ["checked": true])) }
            else if line.hasPrefix("- ") { out.append(block("bulleted_list_item", String(line.dropFirst(2)))) }
            else if line.hasPrefix(">") { out.append(block("quote", line.drop(while: { $0 == ">" || $0 == " " }).description)) }
            else { out.append(block("paragraph", line)) }
        }
        return out
    }
}

/// Resumo da call no Slack, por webhook (mais simples) ou token de bot + canal.
enum Slack {
    static func post(_ t: CallTranscript, config: Config, log: (String) -> Void) {
        guard config.slackEnabled else { return }
        let text = message(t, config: config)
        do {
            if let hook = Keychain.get(Keychain.slackWebhook) {
                _ = try? HTTP.json("POST", hook, headers: [:], body: ["text": text]) // o webhook responde "ok" em texto
            } else if let bot = Keychain.get(Keychain.slackBotToken), !config.slackChannel.isEmpty {
                let r = try HTTP.json("POST", "https://slack.com/api/chat.postMessage", headers: ["Authorization": "Bearer \(bot)"],
                                      body: ["channel": config.slackChannel, "text": text])
                if r["ok"] as? Bool != true { throw HermesError("Slack: \(r["error"] as? String ?? "erro")") }
            } else {
                throw HermesError("Slack ligado sem webhook nem token de bot + canal")
            }
            log("Resumo enviado ao Slack")
        } catch {
            log("Slack falhou: \(error.localizedDescription)")
        }
    }

    /// Markdown → mrkdwn do Slack: seções em negrito, sem links de wiki.
    static func message(_ t: CallTranscript, config: Config) -> String {
        let minutes = max(1, Int((t.duration / 60).rounded()))
        var lines = ["*\(t.title ?? "Call")* · \(minutes) min · \(t.speakers.map(\.label).joined(separator: ", "))"]
        for raw in (t.summary ?? "").components(separatedBy: "\n") {
            var l = raw.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
                .replacingOccurrences(of: "**", with: "*")
            if l.hasPrefix("## ") { l = "*" + l.dropFirst(3) + "*" }
            if l.hasPrefix("- [ ] ") { l = "☐ " + l.dropFirst(6) }
            lines.append(l)
        }
        if let ref = t.notePath, ref.hasPrefix(Notion.prefix), let url = Notion.url(ref) { lines.append("<\(url.absoluteString)|Nota no Notion>") }
        return lines.joined(separator: "\n")
    }
}
