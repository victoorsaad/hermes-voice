import AppKit
import CoreAudio

/// Modo de ditado: o que fazer com o texto depois da transcrição. Fica em modes.json e é editado na aba Modos.
/// O modo vem sozinho do app em foco (ou do site aberto no navegador); dá para fixar um pelo menu.
/// Nada de ditado vira nota; isso é exclusivo das calls.
struct DictationMode: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var symbol: String
    /// Instruções para a IA. Vazio = texto como saiu da transcrição (com vocabulário).
    var instructions: String
    /// Passa pela IA (local ou Claude) antes de colar.
    var polish: Bool
    /// Idioma do texto final ("en", "es"…); nil = o mesmo que você falou.
    var translateTo: String?
    var apps: [String] = []
    /// Trechos de endereço ou título da janela (ex.: "mail.google.com", "linkedin.com").
    var sites: [String] = []
    /// Modo usado quando nenhum outro bate.
    var isDefault = false

    var rawValue: String { name }

    static let languages = [("en", "Inglês"), ("es", "Espanhol"), ("pt", "Português"), ("fr", "Francês"), ("de", "Alemão"), ("it", "Italiano")]
    static func languageName(_ code: String) -> String { languages.first { $0.0 == code }?.1 ?? code }

    /// Prompt final: instruções do modo + tradução + números, ou nil se o modo não usa IA.
    var systemPrompt: String? {
        guard polish || translateTo != nil else { return nil }
        var p = instructions.isEmpty ? Claude.polishPrompt : instructions
        p += "\n" + Self.numbersRule
        if let translateTo {
            p += "\nEscreva o texto final em \(Self.languageName(translateTo).lowercased()), traduzindo com naturalidade (não palavra por palavra)."
        }
        return p
    }

    static let numbersRule = """
    Escreva números, datas, horas, valores e porcentagens em algarismos: "dois mil e vinte e seis" → 2026, \
    "três e meia da tarde" → 15h30, "vinte e cinco reais" → R$ 25, "dez por cento" → 10%, "vinte e três de outubro" → 23 de outubro. \
    Mantenha "um", "uma", "dois" por extenso quando forem artigo ou quantidade pequena no meio da frase ("uma call", "dois minutos").
    """

    /// Comando sobre o texto selecionado ("deixa mais curto", "traduz pro inglês"…).
    static let editPrompt = """
    Você edita um texto seguindo um comando falado. Aplique o comando ao TEXTO SELECIONADO e devolva só o texto resultante, \
    sem comentários e sem aspas. Mantenha o idioma do texto, a não ser que o comando peça tradução. Não invente informação.
    """

    /// Começos de frase que indicam comando sobre a seleção.
    private static let commandVerbs = [
        "deixa", "deixe", "traduz", "traduza", "traduzir", "reescreve", "reescreva", "corrige", "corrija", "resume", "resuma",
        "transforma", "transforme", "formata", "formate", "encurta", "encurte", "melhora", "melhore", "muda", "mude", "coloca",
        "coloque", "põe", "ponha", "tira", "tire", "adiciona", "adicione", "remove", "remova", "faz", "faça", "escreve", "escreva",
        "make", "translate", "rewrite", "fix", "shorten", "summarize", "turn", "format", "add", "remove",
    ]

    static func isCommand(_ text: String) -> Bool {
        let first = text.lowercased().split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        return commandVerbs.contains(first)
    }
}

@MainActor
final class ModeStore: ObservableObject {
    static let shared = ModeStore()
    @Published var modes: [DictationMode] = [] { didSet { save() } }
    /// Modo fixado pelo menu (nil = automático pelo app/site).
    @Published var pinned: UUID?

    private nonisolated static let file = Config.dataDir.appendingPathComponent("modes.json")
    private var file: URL { Self.file }

    private init() { modes = Self.load() }

    /// Lê sem passar pela thread principal (a CLI usa).
    nonisolated static func load() -> [DictationMode] {
        if let data = try? Data(contentsOf: file), let m = try? JSONDecoder().decode([DictationMode].self, from: data), !m.isEmpty {
            return m
        }
        return defaults(polish: Config.load().polishDictation)
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(modes).write(to: file, options: .atomic)
    }

    var fallback: DictationMode { modes.first(where: \.isDefault) ?? modes.first ?? Self.defaults(polish: false)[3] }

    func mode(id: UUID?) -> DictationMode? { modes.first { $0.id == id } }

    /// Fixado > site do navegador > app em foco > padrão.
    func forFrontApp() -> DictationMode {
        if let pinned = mode(id: pinned) { return pinned }
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let modes = modes.filter { !$0.isDefault }
        let page = DictationContext.frontPage()
        if let page, let m = modes.first(where: { $0.sites.contains { site in !site.isEmpty && page.localizedCaseInsensitiveContains(site) } }) {
            return m
        }
        return modes.first { $0.apps.contains(app) } ?? fallback
    }

    nonisolated static func defaults(polish: Bool) -> [DictationMode] {
        [
            DictationMode(name: "Prompt", symbol: "sparkle", instructions: """
            Você recebe um ditado em português que será enviado como instrução para um agente de IA (Claude Code).
            Reescreva como um pedido claro e direto ao agente, no imperativo ("Abra…", "Mude…", "Rode…"), sem inventar nada.
            Mantenha termos técnicos, nomes de arquivos e comandos como foram ditos (ex.: "main ponto swift" → main.swift).
            Exemplo: "cara olha o log do servidor e vê por que o deploy falhou aí corrige e roda os testes" → \
            "Olhe o log do servidor e veja por que o deploy falhou. Depois corrija e rode os testes."
            Responda apenas com o texto final, sem aspas.
            """, polish: polish, apps: [
                "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
                "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.anthropic.claudefordesktop",
                "com.openai.chat", "com.exafunction.windsurf", "dev.zed.Zed",
            ], sites: ["claude.ai", "chatgpt.com"]),
            DictationMode(name: "Mensagem", symbol: "bubble.left.fill", instructions: """
            Você recebe um ditado em português que será enviado como mensagem de chat.
            Corrija pontuação e erros de transcrição, tire vícios de fala no começo e no meio ("é", "então", "tipo", "né", "cara") \
            e mantenha o tom informal e as demais palavras de quem falou. Comece com maiúscula.
            Exemplo: "é então tipo eu acho que dá pra gente ver isso amanhã né" → "Acho que dá pra gente ver isso amanhã."
            Exemplo: "cara você viu o que o Edu mandou tipo ontem" → "Você viu o que o Edu mandou ontem?"
            Se houver texto selecionado (ex.: a mensagem que está sendo respondida), use só como contexto.
            Responda apenas com o texto final, sem aspas.
            """, polish: polish, apps: [
                "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp", "com.apple.MobileSMS", "ru.keepcoder.Telegram",
                "com.hnc.Discord", "com.microsoft.teams2",
            ], sites: ["web.whatsapp.com", "app.slack.com", "linkedin.com/messaging"]),
            DictationMode(name: "E-mail", symbol: "envelope.fill", instructions: """
            Você recebe um ditado em português que vira um e-mail. Organize em parágrafos curtos, com saudação e despedida \
            se fizer sentido, tom cordial e direto. Corrija pontuação e erros de transcrição, tire vícios de fala e não invente informação.
            Responda apenas com o texto do e-mail, sem assunto e sem aspas.
            """, polish: true, apps: ["com.apple.mail", "com.microsoft.Outlook"], sites: ["mail.google.com", "outlook.live.com", "outlook.office.com"]),
            DictationMode(name: "Ditado", symbol: "mic.fill", instructions: "", polish: polish, isDefault: true),
            DictationMode(name: "Inglês", symbol: "globe", instructions: """
            Você recebe um ditado (em qualquer idioma). Corrija erros de transcrição e vícios de fala e mantenha o tom de quem falou.
            Responda apenas com o texto final, sem aspas.
            """, polish: true, translateTo: "en"),
        ]
    }
}

/// Detecta call em andamento: um app de reunião ou navegador usando o microfone (macOS 14.2+).
@MainActor
final class CallDetector {
    private static let meetingApps = [
        "us.zoom.xos": "Zoom", "com.microsoft.teams2": "Teams", "com.microsoft.teams": "Teams",
        "com.apple.FaceTime": "FaceTime", "com.tinyspeck.slackmacgap": "Slack", "com.hnc.Discord": "Discord",
        "com.cisco.webexmeetingsapp": "Webex", "net.whatsapp.WhatsApp": "WhatsApp",
        "com.google.Chrome": "Chrome", "com.apple.Safari": "Safari", "company.thebrowser.Browser": "Arc",
        "com.brave.Browser": "Brave", "org.mozilla.firefox": "Firefox", "com.microsoft.edgemac": "Edge",
    ]

    private var timer: Timer?
    private var active: String?
    private let onChange: (String?) -> Void

    /// `onChange` recebe o nome do app quando uma call começa e nil quando termina.
    init(onChange: @escaping (String?) -> Void) {
        self.onChange = onChange
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        let app = Self.appUsingMic()
        guard app != active else { return }
        active = app
        onChange(app)
    }

    static func appUsingMic() -> String? {
        let me = ProcessInfo.processInfo.processIdentifier
        for process in objects(kAudioHardwarePropertyProcessObjectList, of: AudioObjectID(kAudioObjectSystemObject)) {
            guard uint32(process, kAudioProcessPropertyIsRunningInput) == 1 else { continue }
            var pid: pid_t = 0
            var size = UInt32(MemoryLayout<pid_t>.size)
            var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &pid) == noErr, pid == me { continue }
            guard let bundle = string(process, kAudioProcessPropertyBundleID) else { continue }
            // Processos auxiliares herdam o prefixo do app (ex.: com.google.Chrome.helper).
            if let hit = meetingApps.first(where: { bundle == $0.key || bundle.hasPrefix($0.key + ".") }) { return hit.value }
        }
        return nil
    }

    private static func objects(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
