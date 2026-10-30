import Foundation

/// Configuração em ~/Library/Application Support/Hermes/config.json (criada com os padrões na 1ª execução).
struct Config: Codable {
    var myName = Config.defaultName
    /// Onde a nota da call vai: "markdown" (pasta de Markdown, ex.: um vault do Obsidian) ou "notion" (página num banco do Notion).
    var noteDestination = "markdown"
    /// Pasta de Markdown (vault do Obsidian ou qualquer pasta). Criada na 1ª nota se não existir.
    var vaultPath = NSHomeDirectory() + "/Documents/Hermes"
    var callsFolder = "Calls"
    /// Commit + push só da nota, quando a pasta é um repositório git.
    var gitPush = false
    /// Banco do Notion que recebe as notas (o token fica no Keychain).
    var notionDatabaseID = ""
    /// Posta o resumo da call no Slack (webhook ou token de bot no Keychain; o canal só vale para o bot).
    var slackEnabled = false
    var slackChannel = ""
    var claudePath = NSHomeDirectory() + "/.local/bin/claude"
    var summarizeWithClaude = true
    var polishDictation = false
    /// Similaridade cosseno mínima para reconhecer um perfil de voz salvo.
    var speakerMatchThreshold: Float = 0.6
    /// Idioma da transcrição (Cohere): pt, en, es, fr, de, it…
    var language = "pt"
    /// Pausa música/vídeo enquanto você dita.
    var pauseMedia = true
    /// Outros idiomas que você fala: trechos neles são reconhecidos e transcritos no idioma certo.
    var otherLanguages = ["en", "es"]
    /// Quem pole o ditado: "local" (llama.cpp, ~1–2 s) ou "claude" (assinatura, 5–10 s).
    var polishEngine = "local"
    /// Histórico, áudio dos ditados, modos, vocabulário e vozes no iCloud Drive (pasta Hermes), prontos para outros aparelhos.
    var syncICloud = false

    /// Primeiro nome do usuário do Mac; editável em Ajustes.
    static var defaultName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? "Eu"
    }

    static let dir: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hermes", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// O que é seu (não do aparelho): no iCloud Drive se a sincronização estiver ligada, senão junto do resto.
    /// Modelos, gravações de call, log e config continuam locais. Vale a partir da próxima abertura do app.
    static let dataDir: URL = {
        let icloud = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard load().syncICloud, FileManager.default.fileExists(atPath: icloud.path) else { return dir }
        let url = icloud.appendingPathComponent("Hermes", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        migrate(to: url)
        return url
    }()

    static let syncedItems = ["history.json", "dictations", "modes.json", "vocabulary.txt", "speakers.json"]

    /// 1ª vez com iCloud: copia o que já existe aqui. A cópia local fica como backup (".local") e não é mais usada.
    private static func migrate(to target: URL) {
        let fm = FileManager.default
        for name in syncedItems {
            let local = dir.appendingPathComponent(name), remote = target.appendingPathComponent(name)
            guard fm.fileExists(atPath: local.path) else { continue }
            if !fm.fileExists(atPath: remote.path) {
                guard (try? fm.copyItem(at: local, to: remote)) != nil else { continue }
                Log.write("iCloud: \(name) copiado")
            }
            try? fm.moveItem(at: local, to: dir.appendingPathComponent(name + ".local"))
        }
    }

    static var callsDir: URL {
        let url = dir.appendingPathComponent("calls", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var file: URL { dir.appendingPathComponent("config.json") }

    static func load() -> Config {
        if let data = try? Data(contentsOf: file), let cfg = try? JSONDecoder().decode(Config.self, from: data) {
            return cfg
        }
        let cfg = Config()
        cfg.save()
        return cfg
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Self.file, options: .atomic)
    }
}

extension Config {
    // Campos novos não quebram um config.json antigo.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        myName = try c.decodeIfPresent(String.self, forKey: .myName) ?? myName
        noteDestination = try c.decodeIfPresent(String.self, forKey: .noteDestination) ?? noteDestination
        vaultPath = try c.decodeIfPresent(String.self, forKey: .vaultPath) ?? vaultPath
        notionDatabaseID = try c.decodeIfPresent(String.self, forKey: .notionDatabaseID) ?? notionDatabaseID
        slackEnabled = try c.decodeIfPresent(Bool.self, forKey: .slackEnabled) ?? slackEnabled
        slackChannel = try c.decodeIfPresent(String.self, forKey: .slackChannel) ?? slackChannel
        callsFolder = try c.decodeIfPresent(String.self, forKey: .callsFolder) ?? callsFolder
        gitPush = try c.decodeIfPresent(Bool.self, forKey: .gitPush) ?? gitPush
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath) ?? claudePath
        summarizeWithClaude = try c.decodeIfPresent(Bool.self, forKey: .summarizeWithClaude) ?? summarizeWithClaude
        polishDictation = try c.decodeIfPresent(Bool.self, forKey: .polishDictation) ?? polishDictation
        speakerMatchThreshold = try c.decodeIfPresent(Float.self, forKey: .speakerMatchThreshold) ?? speakerMatchThreshold
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? language
        pauseMedia = try c.decodeIfPresent(Bool.self, forKey: .pauseMedia) ?? pauseMedia
        syncICloud = try c.decodeIfPresent(Bool.self, forKey: .syncICloud) ?? syncICloud
        otherLanguages = try c.decodeIfPresent([String].self, forKey: .otherLanguages) ?? otherLanguages
        polishEngine = try c.decodeIfPresent(String.self, forKey: .polishEngine) ?? polishEngine
    }
}

/// Log simples em ~/Library/Application Support/Hermes/hermes.log (o NSLog de app ad-hoc some do Console).
enum Log {
    private static let url = Config.dir.appendingPathComponent("hermes.log")
    private static let lock = NSLock()

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        lock.withLock {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
