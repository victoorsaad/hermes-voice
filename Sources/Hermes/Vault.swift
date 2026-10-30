import Foundation

/// Destino da nota da call: uma pasta de Markdown (ex.: vault do Obsidian, com commit + push só desse arquivo)
/// ou uma página no Notion. A referência fica em `notePath` (caminho relativo, ou "notion:<id>").
struct Vault {
    let config: Config
    var log: (String) -> Void = { print($0) }

    private var notion: Bool { config.noteDestination == "notion" }

    /// Cria (ou reescreve) a nota. Retorna a referência dela.
    func write(_ t: CallTranscript) throws -> String {
        if notion {
            let ref = try Notion(config: config).write(t, markdown: CallPipeline.markdown(t))
            log("Nota salva no Notion")
            return ref
        }
        let root = URL(fileURLWithPath: config.vaultPath, isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path) {
            // Só cria a pasta se a de cima existe (um disco ou iCloud desmontado não vira pasta nova por engano).
            guard FileManager.default.fileExists(atPath: root.deletingLastPathComponent().path) else {
                throw HermesError("Pasta das notas não encontrada em \(config.vaultPath)")
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let relative: String
        if let existing = t.notePath, !existing.hasPrefix(Notion.prefix) {
            relative = existing
        } else {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HHmm"
            let title = Self.sanitize(t.title ?? "Call")
            relative = "\(config.callsFolder)/\(df.string(from: t.date)) – \(title).md"
        }
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CallPipeline.markdown(t, notes: noteNames()).write(to: url, atomically: true, encoding: .utf8)
        log("Nota salva: \(relative)")
        return relative
    }

    /// Nomes de link das notas do vault: o nome do arquivo, ou o caminho quando dois arquivos têm o mesmo nome.
    func noteNames() -> Set<String> {
        guard !notion else { return [] }
        let root = URL(fileURLWithPath: config.vaultPath, isDirectory: true).standardizedFileURL
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var paths: [String] = []
        for case let url as URL in walker {
            if ["_Media", "Excalidraw"].contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            guard url.pathExtension == "md" else { continue }
            paths.append(String(url.standardizedFileURL.path.dropFirst(root.path.count + 1).dropLast(3)))
        }
        let base = { (p: String) in (p as NSString).lastPathComponent }
        let counts = Dictionary(paths.map { (base($0), 1) }, uniquingKeysWith: +)
        return Set(paths.map { counts[base($0)]! > 1 ? $0 : base($0) })
    }

    /// Commit só da nota (não mexe no resto do vault) e push. Falha de push não é fatal: o próximo push leva junto.
    func commit(_ relative: String, message: String) {
        guard config.gitPush, !relative.hasPrefix(Notion.prefix) else { return }
        let root = config.vaultPath
        guard FileManager.default.fileExists(atPath: root + "/.git") else {
            log("Vault não é um repositório git; pulei o commit")
            return
        }
        let add = Self.git(["add", "--", relative], in: root)
        guard add.status == 0 else { log("git add falhou: \(add.output)"); return }
        let commit = Self.git(["commit", "-m", message, "--", relative], in: root)
        guard commit.status == 0 else { log("git commit: \(commit.output)"); return }
        let push = Self.git(["push"], in: root)
        log(push.status == 0 ? "Enviado ao GitHub" : "Push falhou (tente de novo depois): \(push.output)")
    }

    /// Tira a nota do vault (vai para o Lixo) e registra a exclusão no git.
    func removeNote(_ relative: String, message: String) {
        if relative.hasPrefix(Notion.prefix) {
            do { try Notion(config: config).archive(relative) } catch { log("Notion: \(error.localizedDescription)") }
            return
        }
        let url = URL(fileURLWithPath: config.vaultPath).appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        guard config.gitPush, FileManager.default.fileExists(atPath: config.vaultPath + "/.git") else { return }
        // Nota que nunca foi commitada: não há o que registrar.
        guard Self.git(["ls-files", "--error-unmatch", "--", relative], in: config.vaultPath).status == 0 else { return }
        let rm = Self.git(["rm", "--cached", "-q", "--", relative], in: config.vaultPath)
        guard rm.status == 0 else { log("git rm: \(rm.output)"); return }
        let commit = Self.git(["commit", "-m", message, "--", relative], in: config.vaultPath)
        guard commit.status == 0 else { log("git commit: \(commit.output)"); return }
        let push = Self.git(["push"], in: config.vaultPath)
        log(push.status == 0 ? "Exclusão enviada ao GitHub" : "Push falhou (tente de novo depois): \(push.output)")
    }

    /// Abre a nota no app certo (Obsidian/editor de Markdown ou Notion).
    static func url(for ref: String, config: Config) -> URL? {
        ref.hasPrefix(Notion.prefix) ? Notion.url(ref) : URL(fileURLWithPath: config.vaultPath).appendingPathComponent(ref)
    }

    static func git(_ args: [String], in dir: String) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]")
        return s.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(80).description
    }
}

/// Fluxo completo de uma call já gravada, compartilhado pelo menu e pela CLI.
enum CallFlow {
    static func finish(dir: URL, date: Date, transcriber: Transcriber, config: Config, log: @escaping (String) -> Void) async throws -> CallTranscript {
        var t = try await CallPipeline(transcriber: transcriber, config: config, log: log).process(dir: dir, date: date)
        // Sem nenhuma fala não vale uma nota no vault; o áudio continua na pasta de gravações.
        guard !t.turns.isEmpty else { throw HermesError("Nenhuma fala detectada — nota não criada") }
        let vault = Vault(config: config, log: log)
        let rel = try vault.write(t)
        t.notePath = rel
        try CallPipeline(transcriber: transcriber, config: config).save(t, in: dir)
        vault.commit(rel, message: "Hermes: \(t.title ?? "call") (\(t.id))")
        Slack.post(t, config: config, log: log)
        return t
    }

    /// Troca o rascunho do Parakeet pelo texto do Cohere e reescreve a nota.
    static func refine(dir: URL, transcriber: Transcriber, config: Config, log: @escaping (String) -> Void,
                       pause: @escaping () async -> Bool) async throws {
        let t = try await CallPipeline(transcriber: transcriber, config: config, log: log).refine(dir: dir, pause: pause)
        guard t.notePath != nil else { return }
        let vault = Vault(config: config, log: log)
        var t2 = t
        let rel = try vault.write(t)
        if rel != t.notePath { t2.notePath = rel; try CallPipeline(transcriber: transcriber, config: config).save(t2, in: dir) }
        vault.commit(rel, message: "Hermes: texto refinado (\(t.id))")
    }

    /// Dá nome a falantes desconhecidos: salva o perfil de voz e reescreve a nota.
    static func rename(dir: URL, names: [String: String], config: Config, log: @escaping (String) -> Void) throws -> CallTranscript {
        var t = try CallPipeline.load(dir: dir)
        var profiles = SpeakerProfiles.load()
        for i in t.speakers.indices {
            let old = t.speakers[i].label
            guard let new = names[old]?.trimmingCharacters(in: .whitespaces), !new.isEmpty, new != old else { continue }
            t.speakers[i].label = new
            t.speakers[i].known = true
            if let emb = t.speakers[i].embedding, !emb.isEmpty {
                profiles.enroll(name: new, embedding: emb)
                log("Perfil de voz salvo: \(new)")
            }
        }
        profiles.save()
        let pipeline = CallPipeline(transcriber: Transcriber(), config: config)
        let vault = Vault(config: config, log: log)
        if t.notePath != nil {
            // Remove o callout de "não reconhecidos" ao reescrever.
            let rel = try vault.write(t)
            t.notePath = rel
            vault.commit(rel, message: "Hermes: falantes nomeados (\(t.id))")
        }
        try pipeline.save(t, in: dir)
        return t
    }

    /// Liga uma nota de call já existente às notas do vault (calls de antes dos links) e reescreve a nota.
    static func relink(dir: URL, config: Config, log: @escaping (String) -> Void) async throws {
        var t = try CallPipeline.load(dir: dir)
        guard t.notePath != nil else { log("\(dir.lastPathComponent): sem nota no vault"); return }
        let vault = Vault(config: config, log: log)
        let own = ((t.notePath ?? "") as NSString).deletingPathExtension
        let notes = vault.noteNames().subtracting([own, (own as NSString).lastPathComponent])
        let input = CallPipeline.catalog(notes) + (t.summary ?? "") + "\n\n" + CallPipeline.plainTranscript(t)
        let raw = try await Claude.run(prompt: Claude.relatedPrompt, input: input, claudePath: config.claudePath)
        let related = CallPipeline.splitRelated(raw, notes: notes).1
        t.related = related.isEmpty ? nil : related
        log("\(t.title ?? t.id): \(related.isEmpty ? "nenhuma nota relacionada" : related.joined(separator: ", "))")
        let rel = try vault.write(t)
        t.notePath = rel
        try CallPipeline(transcriber: Transcriber(), config: config).save(t, in: dir)
        vault.commit(rel, message: "Hermes: links da call (\(t.id))")
    }

    static func latestCallDir() -> URL? {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Config.callsDir, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("transcript.json").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }.first
    }
}
