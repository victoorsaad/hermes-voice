import Foundation

/// Transcrição enquanto o áudio cresce. Corta em pausas: trechos fechados são transcritos uma vez e ficam;
/// o trecho aberto (a frase em andamento) é refeito a cada passo e aparece como prévia.
struct LiveSegmenter {
    struct Segment {
        var start: Double
        var text: String
    }

    private(set) var committed: [Segment] = []
    private(set) var partial = ""
    /// Início do trecho aberto, em amostras desde o começo da gravação.
    private(set) var openStart = 0

    private static let rate = Int(Audio.sampleRate)
    private static let frame = rate / 50 // 20 ms
    private static let minPause = 25 // frames = 0,5 s
    private static let minSegment = 3 * rate
    private static let maxSegment = 25 * rate

    /// Só transcreve se houver voz, e descarta texto longo demais para a voz detectada:
    /// em risada, música ou ruído o Cohere "inventa" frases inteiras.
    private func transcribe(_ x: [Float], _ transcriber: Transcriber, _ language: String, _ wait: Bool) async -> String {
        let voice = await transcriber.speechSeconds(x)
        guard voice >= 0.5 else { return "" }
        // Segunda opinião barata: se o Parakeet não ouve nenhuma palavra, não é fala.
        guard let quick = try? await transcriber.transcribe(x), !quick.isEmpty else { return "" }
        let text = (try? await transcriber.text(x, language: language, wait: wait)) ?? ""
        let words = text.split(whereSeparator: \.isWhitespace).count
        return words <= max(3, Int(voice * 6)) ? text : ""
    }

    /// A mesma frase (com mais de 2 palavras) de novo, logo depois, é alucinação típica.
    private func isRepeat(_ t: String) -> Bool {
        let key = Self.normalized(t)
        return key.split(separator: " ").count > 2 && committed.suffix(6).contains { Self.normalized($0.text) == key }
    }

    static func normalized(_ t: String) -> String {
        t.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    var text: String {
        (committed.map(\.text) + [partial]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Avança com as amostras novas do trecho aberto (`open` começa em `openStart`).
    /// `final`: fim da gravação, fecha tudo. `preview`: refaz a prévia da frase em andamento.
    /// Devolve os trechos que acabaram de fechar.
    @discardableResult
    mutating func step(_ open: [Float], transcriber: Transcriber, language: String, final: Bool = false,
                       preview: Bool = true, wait: Bool = false) async -> [Segment] {
        var closed: [Segment] = []
        var rest = open
        while let cut = final ? nil : Self.cutPoint(rest) {
            let seg = Array(rest[..<cut])
            let t = await transcribe(seg, transcriber, language, wait)
            let s = Segment(start: Double(openStart) / Audio.sampleRate, text: t)
            if !t.isEmpty && !isRepeat(t) { committed.append(s); closed.append(s) }
            openStart += cut
            rest = Array(rest[cut...])
        }
        if final {
            let t = rest.count > Self.rate / 2 ? await transcribe(rest, transcriber, language, wait) : ""
            let s = Segment(start: Double(openStart) / Audio.sampleRate, text: t)
            if !t.isEmpty { committed.append(s); closed.append(s) }
            openStart += rest.count
            partial = ""
        } else if preview {
            if rest.count > Self.rate / 2 && Self.hasVoice(rest) {
                partial = await transcribe(rest, transcriber, language, wait)
            }
        }
        return closed
    }

    /// Fim da última pausa (≥ 0,5 s) depois de ≥ 3 s de fala; acima de 25 s corta no ponto mais quieto.
    static func cutPoint(_ x: [Float]) -> Int? {
        guard x.count > minSegment + minPause * frame else { return nil }
        let energies = stride(from: 0, to: x.count - frame, by: frame).map { Audio.rms(x[$0..<$0 + frame]) }
        let floor = energies.sorted()[energies.count / 5]
        let threshold = max(0.003, floor * 2.5)
        var run = 0
        var best: Int?
        for (i, e) in energies.enumerated() {
            run = e < threshold ? run + 1 : 0
            let end = (i + 1) * frame
            // Corta no meio da pausa, para não engolir o começo da próxima frase.
            if run >= minPause, end - run * frame / 2 >= minSegment { best = end - run * frame / 2 }
        }
        if let best { return best }
        guard x.count >= maxSegment else { return nil }
        let window = energies[(minSegment / frame)..<min(energies.count, maxSegment / frame)]
        guard let quiet = window.indices.min(by: { energies[$0] < energies[$1] }) else { return maxSegment }
        return quiet * frame
    }

    static func hasVoice(_ x: [Float]) -> Bool {
        Audio.rms(x[...]) > 0.004
    }
}

extension LiveSegmenter {
    /// Transcreve um áudio inteiro (arquivo) com os mesmos cortes e filtros do ao vivo.
    static func transcribeAll(_ all: [Float], transcriber: Transcriber, language: String,
                              progress: @escaping @Sendable (Double) -> Void) async -> [Segment] {
        var seg = LiveSegmenter()
        var n = 0
        let step = 5 * Int(Audio.sampleRate)
        while n < all.count {
            n = min(all.count, n + step)
            await seg.step(Array(all[seg.openStart..<n]), transcriber: transcriber, language: language, preview: false, wait: true)
            let fraction = Double(n) / Double(max(all.count, 1))
            progress(fraction)
        }
        await seg.step(Array(all[min(seg.openStart, all.count)...]), transcriber: transcriber, language: language, final: true, wait: true)
        return seg.committed
    }
}

/// Estado da call ao vivo: falas (você × Outros), prévias e o chat com o Claude.
@MainActor
final class LiveCall: ObservableObject {
    struct Line: Identifiable {
        let id = UUID()
        var speaker: String
        var start: Double
        var text: String
    }
    struct Message: Identifiable {
        let id = UUID()
        var fromMe: Bool
        var text: String
    }

    @Published var lines: [Line] = []
    @Published var partials: [String: String] = [:]
    @Published var messages: [Message] = []
    @Published var thinking = false
    @Published var running = false
    @Published var startedAt: Date?

    var myName = Config.defaultName

    func add(_ seg: LiveSegmenter.Segment, speaker: String) {
        // Sem fone, o mic repete o que sai do alto-falante: descarta a fala do mic parecida com uma do sistema.
        if speaker == myName, lines.contains(where: { $0.speaker != myName && abs($0.start - seg.start) < 6 && Self.overlap($0.text, seg.text) > 0.5 }) {
            return
        }
        let line = Line(speaker: speaker, start: seg.start, text: seg.text)
        let i = lines.firstIndex { $0.start > seg.start } ?? lines.count
        lines.insert(line, at: i)
    }

    var transcript: String {
        lines.map { "[\(CallPipeline.timestamp($0.start))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    func ask(_ question: String, config: Config) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !thinking else { return }
        messages.append(.init(fromMe: true, text: q))
        thinking = true
        let input = Vocabulary.load().promptHint + "TRANSCRIÇÃO ATÉ AGORA:\n\(transcript)\n\nPERGUNTA: \(q)"
        Task {
            let answer: String
            do {
                answer = try await Claude.run(prompt: Claude.liveCallPrompt, input: input, claudePath: config.claudePath, timeout: 120)
            } catch {
                answer = "Não consegui falar com o Claude: \(error.localizedDescription)"
            }
            messages.append(.init(fromMe: false, text: answer.trimmingCharacters(in: .whitespacesAndNewlines)))
            thinking = false
        }
    }

    /// Fração das palavras de `b` que aparecem em `a`.
    static func overlap(_ a: String, _ b: String) -> Double {
        let wa = Set(a.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        let wb = b.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard !wb.isEmpty else { return 0 }
        return Double(wb.filter { wa.contains($0) }.count) / Double(wb.count)
    }
}
