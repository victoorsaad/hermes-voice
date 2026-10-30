import AppKit
import ApplicationServices

/// IA local para polir ditados: llama-server (Homebrew) com Qwen3-4B, em 127.0.0.1.
/// ~1–2 s por ditado, sem rede e sem gastar a assinatura. O servidor sobe na 1ª vez e fica vivo com o app.
actor LocalLLM {
    static let shared = LocalLLM()
    static let modelFile = Config.dir.appendingPathComponent("models/llm/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")
    private static let port = 8737
    private var server: Process?

    nonisolated static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: modelFile.path) && serverBinary != nil
    }

    private nonisolated static var serverBinary: String? {
        ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Sobe o servidor (se preciso) e espera ficar pronto.
    func start() async throws {
        if await healthy() { return }
        if server?.isRunning != true {
            guard let bin = Self.serverBinary else { throw HermesError("llama-server não encontrado (brew install llama.cpp)") }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["-m", Self.modelFile.path, "--host", "127.0.0.1", "--port", String(Self.port),
                           "-c", "8192", "-ngl", "99", "--jinja", "--log-disable"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            server = p
        }
        for _ in 0..<120 {
            if await healthy() { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw HermesError("IA local não respondeu")
    }

    func stop() {
        server?.terminate()
        server = nil
    }

    private func healthy() async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/health")!)
        req.timeoutInterval = 1
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    func complete(system: String, user: String, maxTokens: Int = 600) async throws -> String {
        try await start()
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "temperature": 0.2, "max_tokens": maxTokens,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let text = (choice["message"] as? [String: Any])?["content"] as? String else {
            throw HermesError("Resposta inválida da IA local")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Contexto do ditado: app em foco e texto selecionado (via Acessibilidade).
enum DictationContext {
    @MainActor
    static func selectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(8000))
    }

    /// Endereço da página no navegador em foco (ou, se não der, o título da janela). Via Acessibilidade, sem AppleScript.
    @MainActor
    static func frontPage() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        guard let window: AXUIElement = attribute(ax, kAXFocusedWindowAttribute) else { return nil }
        let title: String? = attribute(window, kAXTitleAttribute)
        // Procura a área web (Safari, Chrome, Arc…) com busca em largura limitada.
        var queue = [window]
        var visited = 0
        while !queue.isEmpty, visited < 300 {
            let el = queue.removeFirst()
            visited += 1
            if (attribute(el, kAXRoleAttribute) as String?) == "AXWebArea" {
                if let url: URL = attribute(el, kAXURLAttribute) { return url.absoluteString + " " + (title ?? "") }
                if let url: String = attribute(el, kAXURLAttribute) { return url + " " + (title ?? "") }
            }
            if let children: [AXUIElement] = attribute(el, kAXChildrenAttribute) { queue.append(contentsOf: children.prefix(30)) }
        }
        return title
    }

    private static func attribute<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self, CFGetTypeID(value) == AXUIElementGetTypeID() { return (value as! T) }
        return value as? T
    }

    /// Comando falado sobre o texto selecionado.
    static func editMessage(command: String, selection: String) -> String {
        "Comando: \(command)\n\nTEXTO SELECIONADO:\n\"\"\"\n\(selection)\n\"\"\""
    }

    /// Mensagem para o modelo: contexto + ditado, deixando claro o que é para reescrever.
    static func userMessage(text: String, app: String, selection: String?) -> String {
        var m = "App em uso: \(app.isEmpty ? "desconhecido" : app)\n"
        let terms = Vocabulary.load().terms
        if !terms.isEmpty {
            m += "Termos que a pessoa costuma falar, inclusive em inglês no meio do português: \(terms.joined(separator: ", ")).\n"
            m += "Só troque um trecho por um desses termos se ele SOAR quase igual (ex.: \"abacaus\" → \"aba calls\", \"qual\" → \"call\" quando o assunto é ligação). Nunca troque por palavras novas que não estejam no ditado nem nesta lista.\n"
        }
        if let selection { m += "Texto selecionado na tela (só contexto, não reescreva):\n\"\"\"\n\(selection)\n\"\"\"\n" }
        m += "Ditado para reescrever:\n\"\"\"\n\(text)\n\"\"\""
        return m
    }
}
