import Foundation

/// Uso pela linha de comando (testes e reprocessamento):
///   Hermes transcribe <arquivo>
///   Hermes process <pasta com mic.wav/system.wav> [--no-push] [--vault <caminho>] [--no-claude]
///   Hermes name <pasta> "Pessoa 1=Bruno" ["Pessoa 2=Ana" …]
enum CLI {
    static func run(_ args: [String]) -> Int32 {
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task.detached {
            do { try await dispatch(args) } catch {
                FileHandle.standardError.write(Data("erro: \(error.localizedDescription)\n".utf8))
                code = 1
            }
            sem.signal()
        }
        sem.wait()
        return code
    }

    private static func dispatch(_ args: [String]) async throws {
        var config = Config.load()
        if let i = args.firstIndex(of: "--vault"), i + 1 < args.count { config.vaultPath = args[i + 1] }
        if args.contains("--no-push") { config.gitPush = false }
        if args.contains("--no-claude") { config.summarizeWithClaude = false }

        switch args.first {
        case "transcribe":
            guard args.count > 1 else { throw HermesError("uso: Hermes transcribe <arquivo>") }
            let samples = try Audio.readAny(URL(fileURLWithPath: args[1]))
            let tr = Transcriber()
            let t0 = Date()
            let segments = await LiveSegmenter.transcribeAll(samples, transcriber: tr, language: config.language) { _ in }
            print(segments.map(\.text).joined(separator: " "))
            FileHandle.standardError.write(Data(String(format: "(%.1fs, inclui ~2 min de aquecimento do modelo)\n", Date().timeIntervalSince(t0)).utf8))
        case "icon":
            // Hermes icon <pasta.iconset>: gera os PNGs do ícone (o bundle.sh converte em .icns).
            guard args.count > 1 else { throw HermesError("uso: Hermes icon <pasta.iconset>") }
            try Logo.writeIconset(to: URL(fileURLWithPath: args[1]))
            print(args[1])
        case "aac":
            // Hermes aac <wav>: grava em AAC e lê de volta (teste do áudio dos ditados).
            let samples = try Audio.readAny(URL(fileURLWithPath: args[1]))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-teste.m4a")
            try History.writeAAC(samples, to: url)
            let back = try History.readAudio(url)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            print("\(samples.count) → \(back.count) amostras, \(size / 1024) KB")
            let tr = Transcriber()
            print(try await tr.text(back, language: config.language))
        case "modelos":
            // Hermes modelos [pasta]: mostra o que falta; com pasta, baixa o vocab do Cohere lá (teste do download).
            print("faltando: Cohere \(Models.missing(Models.cohere).count) arq., IA local \(Models.missing(Models.llm).count) arq., programas: \(Models.missingTools)")
            if args.count > 1 {
                let f = Models.cohere[0]
                let test = Models.File(url: f.url, destination: URL(fileURLWithPath: args[1]).appendingPathComponent("vocab.json"), size: f.size)
                try await Models.download([test]) { p in FileHandle.standardError.write(Data(String(format: "%.0f%% ", p * 100).utf8)) }
                print("\nbaixado: \(test.destination.path)")
            }
        case "resposta":
            let r = AgentHook.interpret(args.dropFirst().joined(separator: " "))
            print(r.allow ? "permitir" : "negar", r.message.map { "— \($0)" } ?? "")
        case "numeros":
            print(Numbers.normalize(args.dropFirst().joined(separator: " ")))
        case "media":
            // Hermes media: diz se o sistema vê mídia tocando (sem pausar nada).
            let paused = Media.pauseIfPlaying()
            if paused { Media.resume() }
            print(paused ? "tocando (pausei e retomei)" : "nada tocando — não mexo")
        case "polish":
            // Hermes polish <prompt|mensagem|ditado> "texto": testa o polimento com a IA local.
            guard args.count > 2 else { throw HermesError("uso: Hermes polish <modo> \"texto\" [\"seleção\"]") }
            let modes = ModeStore.load()
            guard let mode = modes.first(where: { $0.name.lowercased() == args[1].lowercased() }) else {
                throw HermesError("modos: \(modes.map(\.name).joined(separator: ", "))")
            }
            let t0 = Date()
            let out = await Polisher.run(args[2], mode: mode, app: "Teste", selection: args.count > 3 ? args[3] : nil, config: config)
            print(out)
            FileHandle.standardError.write(Data(String(format: "(%.1fs)\n", Date().timeIntervalSince(t0)).utf8))
        case "hooks":
            // Hermes hooks on|off: avisos do Claude Code na pílula (edita ~/.claude/settings.json).
            try AgentHook.setInstalled(args.dropFirst().first != "off")
            print("hooks do Claude Code: \(AgentHook.isInstalled ? "ligados" : "desligados")")
        case "vocab":
            // Hermes vocab "texto": mostra a correção pelo vocabulário.
            print(Vocabulary.load().apply(args.dropFirst().joined(separator: " ")))
        case "live":
            // Hermes live <arquivo> [segundos]: simula a transcrição ao vivo, 1 s de áudio por passo.
            guard args.count > 1 else { throw HermesError("uso: Hermes live <arquivo> [segundos]") }
            var all = try Audio.readWAV(URL(fileURLWithPath: args[1]))
            if args.count > 2, let secs = Double(args[2]) { all = Array(all.prefix(Int(secs * Audio.sampleRate))) }
            let tr = Transcriber()
            _ = await tr.warmUp()
            var seg = LiveSegmenter()
            var n = 0
            var busy = 0.0
            while n < all.count {
                n = min(all.count, n + Int(Audio.sampleRate))
                let t0 = Date()
                for c in await seg.step(Array(all[seg.openStart..<n]), transcriber: tr, language: config.language) {
                    print(String(format: "[%@] %@", CallPipeline.timestamp(c.start), c.text))
                }
                busy += Date().timeIntervalSince(t0)
            }
            await seg.step(Array(all[seg.openStart...]), transcriber: tr, language: config.language, final: true)
            print(String(format: "— %.0f s de áudio, %.0f s de processamento", Double(all.count) / Audio.sampleRate, busy))
        case "process":
            guard args.count > 1 else { throw HermesError("uso: Hermes process <pasta>") }
            let t = try await CallFlow.finish(dir: URL(fileURLWithPath: args[1]), date: Date(),
                                              transcriber: Transcriber(), config: config) { print("· \($0)") }
            print("\n" + CallPipeline.markdown(t))
            print("· Refinando o texto com o Cohere…")
            try await CallFlow.refine(dir: URL(fileURLWithPath: args[1]), transcriber: Transcriber(), config: config,
                                      log: { print("· \($0)") }, pause: { false })
        case "relink":
            // Hermes relink [pasta]: põe os links do vault nas notas de call (todas, sem pasta).
            let dirs = args.count > 1 && !args[1].hasPrefix("--") ? [URL(fileURLWithPath: args[1])]
                : ((try? FileManager.default.contentsOfDirectory(at: Config.callsDir, includingPropertiesForKeys: nil)) ?? [])
                    .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("transcript.json").path) }
            for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try await CallFlow.relink(dir: dir, config: config) { print("· \($0)") }
            }
        case "bench":
            // Hermes bench <pasta>: só o pipeline (sem vault), com o tempo de cada etapa.
            guard args.count > 1 else { throw HermesError("uso: Hermes bench <pasta>") }
            let t0 = Date()
            var last = t0
            _ = try await CallPipeline(transcriber: Transcriber(), config: config) { msg in
                print(String(format: "[%5.1f s, etapa anterior %5.1f s] %@", Date().timeIntervalSince(t0), Date().timeIntervalSince(last), msg))
                last = Date()
            }.process(dir: URL(fileURLWithPath: args[1]))
            print(String(format: "[%5.1f s] nota pronta (rascunho Parakeet)", Date().timeIntervalSince(t0)))
            if args.count > 2, args[2] == "--refine" {
                _ = try await CallPipeline(transcriber: Transcriber(), config: config).refine(dir: URL(fileURLWithPath: args[1]))
                print(String(format: "[%5.1f s] texto refinado", Date().timeIntervalSince(t0)))
            }
        case "record":
            // Hermes record <segundos> <pasta>: grava mic + sistema (teste de captura).
            guard args.count > 2, let secs = Double(args[1]) else { throw HermesError("uso: Hermes record <segundos> <pasta>") }
            let dir = URL(fileURLWithPath: args[2])
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let mic = Recorder(), sys = SystemAudioRecorder()
            try mic.start()
            do { try sys.start() } catch { print("sistema: \(error.localizedDescription)") }
            try await Task.sleep(nanoseconds: UInt64(secs * 1e9))
            let m = mic.stop(), s = sys.stop()
            try Audio.writeWAV(m, to: dir.appendingPathComponent("mic.wav"))
            try Audio.writeWAV(s, to: dir.appendingPathComponent("system.wav"))
            print(String(format: "mic: %.1fs rms %.4f · sistema: %.1fs rms %.4f",
                         Double(m.count) / Audio.sampleRate, Audio.rms(m[...]), Double(s.count) / Audio.sampleRate, Audio.rms(s[...])))
        case "name":
            guard args.count > 2 else { throw HermesError("uso: Hermes name <pasta> \"Pessoa 1=Nome\"") }
            var names: [String: String] = [:]
            for pair in args.dropFirst(2) where pair.contains("=") && !pair.hasPrefix("--") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                names[parts[0]] = parts[1]
            }
            let t = try CallFlow.rename(dir: URL(fileURLWithPath: args[1]), names: names, config: config) { print("· \($0)") }
            print(t.speakers.map(\.label).joined(separator: ", "))
        default:
            throw HermesError("comandos: transcribe | process | name")
        }
    }
}
