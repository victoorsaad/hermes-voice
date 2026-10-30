import Foundation

/// Depois da transcrição: comando sobre a seleção, ou o modo (polimento, tradução, números). Usado no ditado e no "Refazer".
enum Polisher {
    enum Kind { case none, polish, translate, edit }

    /// O que vai acontecer com esse texto (para a pílula mostrar "Traduzindo", "Editando seleção"…).
    static func kind(_ text: String, mode: DictationMode, selection: String?) -> Kind {
        if selection != nil, DictationMode.isCommand(text) { return .edit }
        if mode.translateTo != nil { return .translate }
        return mode.systemPrompt == nil ? .none : .polish
    }

    static func run(_ text: String, mode: DictationMode, app: String, selection: String?, config: Config) async -> String {
        guard !text.isEmpty else { return text }
        let system: String, user: String
        switch kind(text, mode: mode, selection: selection) {
        case .none:
            return text
        case .edit:
            system = DictationMode.editPrompt
            user = DictationContext.editMessage(command: text, selection: selection ?? "")
        case .polish, .translate:
            system = mode.systemPrompt ?? Claude.polishPrompt
            user = DictationContext.userMessage(text: text, app: app, selection: selection)
        }
        let local = config.polishEngine == "local" && LocalLLM.isAvailable
        let out = local
            ? try? await LocalLLM.shared.complete(system: system, user: user, maxTokens: 2000)
            : try? await Claude.run(prompt: system, input: user, claudePath: config.claudePath, timeout: 60)
        guard let out, !out.isEmpty else { return text }
        return out
    }

    static func label(_ kind: Kind, mode: DictationMode) -> String {
        switch kind {
        case .none: "Transcrevendo"
        case .polish: "Polindo"
        case .translate: "Traduzindo para \(DictationMode.languageName(mode.translateTo ?? "en").lowercased())"
        case .edit: "Editando a seleção"
        }
    }
}
