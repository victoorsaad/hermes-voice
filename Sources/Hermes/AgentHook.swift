import AppKit

/// Integração com o Claude Code: hooks Stop e Notification chamam `Hermes agent-hook`, que repassa o evento
/// ao app por notificação distribuída. O app mostra na pílula ("terminou", "pede permissão") e um clique
/// volta para o terminal certo — aí é só segurar ⌥ e responder por voz.
enum AgentHook {
    /// Prefixo das notificações: o bundle id do app (definido no bundle.sh por HERMES_BUNDLE_ID).
    private static let prefix = Bundle.main.bundleIdentifier ?? "io.github.hermes-voice"
    static let notification = Notification.Name(prefix + ".agent")
    static let command = "'/Applications/Hermes.app/Contents/MacOS/Hermes' agent-hook"
    static let permissionCommand = "'/Applications/Hermes.app/Contents/MacOS/Hermes' permission-hook"
    static let permissionRequest = Notification.Name(prefix + ".permission")
    static let permissionReply = Notification.Name(prefix + ".permission.reply")
    /// Evento → (comando, timeout). O de permissão espera sua resposta por até ~2 min.
    private static let events: [(String, String, Int)] = [
        ("Stop", command, 5), ("Notification", command, 5), ("PermissionRequest", permissionCommand, 130),
    ]
    private static var settingsURL: URL { URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json") }

    struct Event: Codable {
        var kind: String // stop | permission | waiting | other
        var project: String
        var text: String
        var bundle: String
    }

    // MARK: - Lado do hook (processo curto, chamado pelo Claude Code)

    /// Lê o JSON do hook no stdin e avisa o app. Nunca falha: um hook com erro atrapalharia o Claude Code.
    static func run() {
        let env = ProcessInfo.processInfo.environment
        // Só sessões interativas: agentes em segundo plano (sem terminal) não interessam.
        guard env["TERM_PROGRAM"] != nil || env["__CFBundleIdentifier"] != nil else { return }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let name = input["hook_event_name"] as? String ?? ""
        let cwd = input["cwd"] as? String ?? ""
        var event = Event(kind: "other", project: URL(fileURLWithPath: cwd).lastPathComponent, text: "",
                          bundle: env["__CFBundleIdentifier"] ?? terminalBundle(env["TERM_PROGRAM"]))
        if name == "Stop" {
            if input["stop_hook_active"] as? Bool == true { return }
            event.kind = "stop"
            event.text = (input["transcript_path"] as? String).flatMap(lastAssistantText) ?? ""
        } else if name == "Notification" {
            let message = input["message"] as? String ?? ""
            if message.localizedCaseInsensitiveContains("permission") {
                event.kind = "permission"
                event.text = message.components(separatedBy: " to use ").last.map { "usar \($0)" } ?? message
            } else if message.localizedCaseInsensitiveContains("waiting") {
                event.kind = "waiting"
            } else {
                event.text = message
            }
        } else {
            return
        }
        guard let json = try? JSONEncoder().encode(event), let payload = String(data: json, encoding: .utf8) else { return }
        DistributedNotificationCenter.default().postNotificationName(notification, object: payload, userInfo: nil, deliverImmediately: true)
    }

    private static func terminalBundle(_ program: String?) -> String {
        switch program {
        case "Apple_Terminal": "com.apple.Terminal"
        case "iTerm.app": "com.googlecode.iterm2"
        case "vscode": "com.microsoft.VSCode"
        case "WarpTerminal": "dev.warp.Warp-Stable"
        case "ghostty": "com.mitchellh.ghostty"
        default: ""
        }
    }

    /// Primeira frase da última resposta do Claude na sessão (o transcript é JSONL).
    private static func lastAssistantText(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 200_000 ? size - 200_000 : 0)
        guard let tail = String(data: handle.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        for line in tail.split(separator: "\n").reversed() {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            if let text = content.last(where: { $0["type"] as? String == "text" })?["text"] as? String, !text.isEmpty {
                let flat = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "*", with: "")
                let sentence = flat.split(separator: ".", maxSplits: 1).first.map(String.init) ?? flat
                return sentence.count > 110 ? String(sentence.prefix(110)) + "…" : sentence
            }
        }
        return nil
    }

    // MARK: - Permissão por voz (hook PermissionRequest)

    struct PermissionAsk: Codable {
        var id: String
        var project: String
        var tool: String
        var summary: String
        var bundle: String
    }

    struct PermissionAnswer: Codable {
        var id: String
        /// ack (app recebeu), pass (deixa o terminal perguntar), allow, deny
        var action: String
        var message: String?
    }

    /// Chamado pelo Claude Code antes de mostrar o pedido de permissão. Pergunta ao app (pílula + voz) e devolve a decisão.
    /// Sem app aberto, sem resposta ou com o terminal na frente: não decide nada e o Claude Code pergunta como sempre.
    static func runPermission() {
        let env = ProcessInfo.processInfo.environment
        guard env["TERM_PROGRAM"] != nil || env["__CFBundleIdentifier"] != nil else { return }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let tool = input["tool_name"] as? String ?? "?"
        let toolInput = input["tool_input"] as? [String: Any] ?? [:]
        let summary = ["command", "file_path", "url", "pattern", "description", "prompt"]
            .lazy.compactMap { toolInput[$0] as? String }.first ?? ""
        let ask = PermissionAsk(id: UUID().uuidString, project: URL(fileURLWithPath: input["cwd"] as? String ?? "").lastPathComponent,
                                tool: tool, summary: String(summary.prefix(300)),
                                bundle: env["__CFBundleIdentifier"] ?? terminalBundle(env["TERM_PROGRAM"]))

        var answer: PermissionAnswer?
        var acked = false
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(forName: permissionReply, object: nil, queue: nil) { n in
            guard let s = n.object as? String, let a = try? JSONDecoder().decode(PermissionAnswer.self, from: Data(s.utf8)), a.id == ask.id else { return }
            if a.action == "ack" { acked = true } else { answer = a }
        }
        defer { center.removeObserver(observer) }
        guard let payload = try? JSONEncoder().encode(ask) else { return }
        center.postNotificationName(permissionRequest, object: String(decoding: payload, as: UTF8.self), userInfo: nil, deliverImmediately: true)

        let start = Date()
        while answer == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let waited = Date().timeIntervalSince(start)
            if !acked && waited > 1.5 { return }   // Hermes fechado
            if waited > 120 { return }              // ninguém respondeu: o terminal pergunta
        }
        guard let answer, answer.action == "allow" || answer.action == "deny" else { return }
        var decision: [String: Any] = ["behavior": answer.action]
        if answer.action == "deny", let m = answer.message, !m.isEmpty { decision["message"] = m }
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        if let json = try? JSONSerialization.data(withJSONObject: out) {
            FileHandle.standardOutput.write(json)
        }
    }

    static func reply(_ answer: PermissionAnswer) {
        guard let data = try? JSONEncoder().encode(answer) else { return }
        DistributedNotificationCenter.default().postNotificationName(permissionReply, object: String(decoding: data, as: UTF8.self),
                                                                     userInfo: nil, deliverImmediately: true)
    }

    /// Resposta falada → decisão. "sim / pode / manda" permite; "não …" nega (o resto vai como explicação ao Claude);
    /// qualquer outra frase nega e vira a instrução para o Claude ("usa a pasta de testes em vez disso").
    static func interpret(_ spoken: String) -> (allow: Bool, message: String?) {
        let words = spoken.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard let first = words.first else { return (false, nil) }
        let yes: Set = ["sim", "pode", "podes", "permite", "permito", "permitir", "manda", "vai", "ok", "okay", "beleza", "claro",
                        "yes", "aprovado", "aprovo", "autorizo", "autorizado", "libera", "liberado", "bora", "segue", "isso", "yeah", "yep", "sure"]
        let no: Set = ["não", "nao", "nega", "negado", "cancela", "para", "pare", "no", "nope", "espera"]
        if yes.contains(first), !words.contains("não"), !words.contains("nao") { return (true, nil) }
        if no.contains(first) {
            let rest = spoken.drop { $0.isLetter }.drop { !$0.isLetter }
            return (false, rest.isEmpty ? nil : String(rest))
        }
        return (false, spoken)
    }

    // MARK: - Instalação em ~/.claude/settings.json

    static var isInstalled: Bool {
        guard let hooks = settings()?["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { contains(hooks[$0.0]) }
    }

    /// Liga/desliga os hooks preservando todo o resto do settings.json.
    static func setInstalled(_ on: Bool) throws {
        var root = settings() ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, cmd, timeout) in events {
            var groups = (hooks[event] as? [[String: Any]] ?? []).compactMap { group -> [String: Any]? in
                var g = group
                let list = (g["hooks"] as? [[String: Any]] ?? []).filter { !isOurs($0["command"] as? String) }
                if list.isEmpty { return nil }
                g["hooks"] = list
                return g
            }
            if on { groups.append(["hooks": [["type": "command", "command": cmd, "timeout": timeout]]]) }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        root["hooks"] = hooks
        let backup = settingsURL.appendingPathExtension("antes-do-hermes")
        if !FileManager.default.fileExists(atPath: backup.path) { try? FileManager.default.copyItem(at: settingsURL, to: backup) }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    private static func contains(_ value: Any?) -> Bool {
        (value as? [[String: Any]] ?? []).contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { isOurs($0["command"] as? String) }
        }
    }

    private static func isOurs(_ command: String?) -> Bool {
        guard let command else { return false }
        return command.contains("Hermes' agent-hook") || command.contains("Hermes' permission-hook")
    }

    private static func settings() -> [String: Any]? {
        (try? Data(contentsOf: settingsURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}
