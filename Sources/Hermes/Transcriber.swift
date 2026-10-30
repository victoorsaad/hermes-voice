import NaturalLanguage
import CoreML
import FluidAudio
import Foundation

struct Word {
    let text: String
    let start: Double
    let end: Double
}

/// Modelos locais no Neural Engine:
/// - Cohere Transcribe (idioma fixo, ex. PT): o texto final do ditado e das calls.
/// - Parakeet TDT v3: tempo por palavra (alinhar falantes e detectar eco). Detecta o idioma sozinho e erra em frases curtas.
/// - Diarização pyannote community-1.
actor Transcriber {
    private var asr: AsrManager?
    private var diarizer: OfflineDiarizerManager?
    private var cohere: CoherePipeline?
    private var cohereModels: CoherePipeline.LoadedModels?
    private var cohereMissing = false

    private var vad: VadManager?

    /// Segundos com voz (Silero VAD, janelas de 256 ms). O Cohere inventa frases em silêncio/ruído; isso filtra antes.
    func speechSeconds(_ samples: [Float]) async -> Double {
        do {
            if vad == nil { vad = try await VadManager() }
            guard let vad else { return 0 }
            let results = try await vad.process(samples)
            return Double(results.filter { $0.probability >= 0.5 }.count) * Double(VadManager.chunkSize) / Audio.sampleRate
        } catch {
            return Double(samples.count) / Audio.sampleRate
        }
    }

    static let cohereDir = Config.dir.appendingPathComponent("models/cohere", isDirectory: true)

    /// Carrega o Cohere se os modelos já estiverem em models/cohere; senão o texto sai do Parakeet.
    func loadCohere() async -> Bool {
        if cohereModels != nil { return true }
        if cohereMissing { return false }
        do {
            // GPU: ~0,8 s por trecho depois de aquecido (o ANE leva 1,5–3 s).
            cohereModels = try await CoherePipeline.loadModels(encoderDir: Self.cohereDir, decoderDir: Self.cohereDir, vocabDir: Self.cohereDir, computeUnits: .cpuAndGPU)
            cohere = CoherePipeline()
            return true
        } catch {
            NSLog("Hermes: Cohere indisponível (%@), usando Parakeet", error.localizedDescription)
            cohereMissing = true
            return false
        }
    }

    /// Depois de baixar os modelos: tenta carregar de novo.
    func retryCohere() { cohereMissing = false }

    private var warmTask: Task<Bool, Never>?
    private var cohereWarm = false

    /// A 1ª inferência do Cohere em cada processo compila os shaders (~2 min). Roda isso cedo, em segundo plano.
    func warmUp() async -> Bool {
        if let warmTask { return await warmTask.value }
        let task = Task { () -> Bool in
            guard await self.loadCohere(), let cohere = await self.cohere, let models = await self.cohereModels else { return false }
            let silence = [Float](repeating: 0, count: Int(Audio.sampleRate))
            _ = try? await cohere.transcribe(audio: silence, models: models, language: .portuguese)
            await self.markWarm()
            return true
        }
        warmTask = task
        return await task.value
    }

    private func markWarm() { cohereWarm = true }

    /// Texto final de um trecho, no idioma configurado. `wait`: espera o Cohere aquecer (calls);
    /// sem esperar (ditado), usa o Parakeet enquanto ele não está pronto.
    /// Texto final. `language` é o idioma principal; com `others`, cada trecho tem o idioma detectado
    /// (o Parakeet ouve primeiro, o NaturalLanguage decide) e o Cohere transcreve já no idioma certo.
    /// `draft`: texto do Parakeet já pronto para o trecho (evita transcrever de novo só para detectar o idioma).
    func text(_ samples: [Float], language: String, others: [String]? = nil, wait: Bool = true, draft known: String? = nil) async throws -> String {
        let others = (others ?? Config.load().otherLanguages).filter { $0 != language }
        guard samples.count > Int(Audio.sampleRate) / 4 else { return "" }
        var ready = cohereWarm
        if !ready && wait { ready = await warmUp() }
        guard ready, let cohere, let cohereModels else {
            return Vocabulary.load().apply(try await transcribe(samples))
        }
        var lang = language
        var draft = known
        if !others.isEmpty {
            if draft == nil { draft = try? await transcribe(samples) }
            if let draft { lang = Self.detect(draft, primary: language, others: others) }
        }
        let code = CohereAsrConfig.Language(rawValue: lang) ?? .portuguese
        let r = samples.count <= CohereAsrConfig.maxSamples
            ? try await cohere.transcribe(audio: samples, models: cohereModels, language: code)
            : try await cohere.transcribeLong(audio: samples, models: cohereModels, language: code)
        var out = Self.clean(r.text)
        // Às vezes o Cohere "escapa" para outro alfabeto ("Na aba calls" → "Набаколс"): fica com o Parakeet.
        if Self.hasForeignScript(out) {
            if draft == nil { draft = try? await transcribe(samples) }
            if let draft, !Self.hasForeignScript(draft) { out = draft }
        }
        out = Vocabulary.load().apply(out)
        return lang == "pt" ? Numbers.normalize(out) : out
    }

    /// Idioma do trecho: só troca do principal com confiança alta (frase curta em PT às vezes parece espanhol).
    static func detect(_ text: String, primary: String, others: [String]) -> String {
        guard text.split(separator: " ").count >= 3 else { return primary }
        let r = NLLanguageRecognizer()
        let all = [primary] + others
        r.languageConstraints = all.map { NLLanguage(rawValue: $0) }
        r.processString(text)
        let hyp = r.languageHypotheses(withMaximum: 3)
        guard let (best, p) = hyp.max(by: { $0.value < $1.value }), best.rawValue != primary, p >= 0.85 else { return primary }
        return best.rawValue
    }

    static func hasForeignScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { s in
            s.properties.isAlphabetic && !(0x0000...0x024F).contains(s.value) && !(0x1E00...0x1EFF).contains(s.value)
        }
    }

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func load() async throws {
        guard asr == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asr = manager
    }

    func loadDiarizer() async throws -> OfflineDiarizerManager {
        if let diarizer { return diarizer }
        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels()
        diarizer = manager
        return manager
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        try await load()
        guard let asr, samples.count > Int(Audio.sampleRate) / 4 else { return "" }
        var state = TdtDecoderState.make()
        let result = try await asr.transcribe(samples, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Transcreve com tempo por palavra (para atribuir cada palavra a um falante).
    func words(_ samples: [Float]) async throws -> [Word] {
        try await load()
        guard let asr, samples.count > Int(Audio.sampleRate) / 2 else { return [] }
        var state = TdtDecoderState.make()
        let result = try await asr.transcribe(samples, decoderState: &state)
        return Self.mergeTokens(result.tokenTimings ?? [])
    }

    /// nil quando o áudio tem som mas nenhuma fala (música, notificações, silêncio com ruído).
    func diarize(_ samples: [Float]) async throws -> DiarizationResult? {
        let manager = try await loadDiarizer()
        do {
            return try await manager.process(audio: samples)
        } catch OfflineDiarizationError.noSpeechDetected {
            return nil
        }
    }

    /// Peças SentencePiece → palavras; "▁" ou espaço inicial marca começo de palavra.
    static func mergeTokens(_ tokens: [TokenTiming]) -> [Word] {
        var words: [Word] = []
        var text = ""
        var start = 0.0
        var end = 0.0
        func flush() {
            let t = text.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { words.append(Word(text: t, start: start, end: end)) }
            text = ""
        }
        for tok in tokens {
            let piece = tok.token.replacingOccurrences(of: "▁", with: " ")
            if piece.hasPrefix(" ") || text.isEmpty {
                flush()
                start = tok.startTime
            }
            text += piece
            end = tok.endTime
        }
        flush()
        return words
    }
}
