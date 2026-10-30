import FluidAudio
import Foundation

/// Transcrição final de uma call, salva como transcript.json ao lado dos WAVs.
struct CallTranscript: Codable {
    struct Speaker: Codable {
        var id: String
        var label: String
        var known: Bool
        var embedding: [Float]?
    }
    struct Turn: Codable {
        var speaker: String
        var start: Double
        var text: String
        /// Fim do trecho; presente enquanto o texto ainda é o rascunho do Parakeet (some depois do refino com o Cohere).
        var end: Double?
    }

    var id: String
    var date: Date
    var duration: Double
    var speakers: [Speaker]
    var turns: [Turn]
    var title: String?
    var summary: String?
    var notePath: String?
    /// Notas do vault ligadas à call (nomes de link já conferidos com o vault).
    var related: [String]?
    /// Nome sugerido pelo Claude para cada "Pessoa N", com o indício.
    var suggestions: [String: Suggestion]?

    struct Suggestion: Codable {
        var name: String
        var reason: String
    }

    func label(_ speakerID: String) -> String {
        speakers.first { $0.id == speakerID }?.label ?? speakerID
    }
}

/// mic.wav (você) + system.wav (os outros) → falantes identificados → resumo Claude → nota (Markdown ou Notion).
struct CallPipeline {
    let transcriber: Transcriber
    var config: Config
    var log: (String) -> Void = { print($0) }

    static let meID = "me"

    func process(dir: URL, date: Date = Date()) async throws -> CallTranscript {
        let micURL = dir.appendingPathComponent("mic.wav")
        let sysURL = dir.appendingPathComponent("system.wav")
        let fm = FileManager.default
        let mic = fm.fileExists(atPath: micURL.path) ? try Audio.readWAV(micURL) : []
        let sys = fm.fileExists(atPath: sysURL.path) ? try Audio.readWAV(sysURL) : []
        guard !mic.isEmpty || !sys.isEmpty else { throw HermesError("Nenhum áudio em \(dir.path)") }

        log("Transcrevendo seu microfone…")
        var micWords = try await transcriber.words(mic)

        var speakers: [CallTranscript.Speaker] = []
        if !micWords.isEmpty {
            speakers.append(.init(id: Self.meID, label: config.myName, known: true, embedding: nil))
        }

        var tagged: [(Word, String)] = []
        if Audio.rms(sys[...]) > 0.0005 {
            log("Separando falantes do áudio do sistema…")
        }
        if Audio.rms(sys[...]) > 0.0005, let diar = try await transcriber.diarize(sys) {
            log("Transcrevendo áudio do sistema…")
            // Um trecho por turno de fala: o ASR não "pula" falas de uma voz quando outra domina o arquivo.
            var sysWords: [Word] = []
            for turn in Self.speakerTurns(diar.segments) {
                let a = max(0, Int((turn.start - 0.2) * Audio.sampleRate))
                let b = min(sys.count, Int((turn.end + 0.3) * Audio.sampleRate))
                guard b - a > Int(Audio.sampleRate / 2) else { continue }
                let offset = Double(a) / Audio.sampleRate
                let words = try await transcriber.words(Array(sys[a..<b]))
                sysWords += words.map { Word(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
            }

            let profiles = SpeakerProfiles.load()
            var unknownCount = 0
            let ids = Array(Set(diar.segments.map(\.speakerId))).sorted()
            // Ordena por primeira fala para "Pessoa 1" ser quem falou primeiro.
            let firstSpoke = Dictionary(grouping: diar.segments, by: \.speakerId).mapValues { $0.map(\.startTimeSeconds).min() ?? 0 }
            for sid in ids.sorted(by: { firstSpoke[$0, default: 0] < firstSpoke[$1, default: 0] }) {
                let emb = diar.speakerDatabase?[sid]
                    ?? Self.meanEmbedding(diar.segments.filter { $0.speakerId == sid }.map(\.embedding))
                if let m = profiles.match(emb, threshold: config.speakerMatchThreshold) {
                    log("Reconheci \(m.name) (similaridade \(String(format: "%.2f", m.score)))")
                    speakers.append(.init(id: sid, label: m.name, known: true, embedding: emb))
                } else {
                    unknownCount += 1
                    speakers.append(.init(id: sid, label: "Pessoa \(unknownCount)", known: false, embedding: emb))
                }
            }

            for w in sysWords {
                let mid = Float((w.start + w.end) / 2)
                let seg = diar.segments.first { mid >= $0.startTimeSeconds && mid <= $0.endTimeSeconds }
                    ?? diar.segments.min { abs(($0.startTimeSeconds + $0.endTimeSeconds) / 2 - mid) < abs(($1.startTimeSeconds + $1.endTimeSeconds) / 2 - mid) }
                tagged.append((w, seg?.speakerId ?? "sys"))
            }
            if tagged.contains(where: { $0.1 == "sys" }) && !speakers.contains(where: { $0.id == "sys" }) {
                speakers.append(.init(id: "sys", label: "Outros", known: false, embedding: nil))
            }

            // Sem fone, o mic capta o alto-falante. Uma palavra do mic é eco se lembra uma palavra do sistema
            // dita perto (±1,5 s). Se a maioria das palavras do mic durante um turno alheio é eco, o trecho todo é eco.
            let before = micWords.count
            let isEcho = micWords.map { mw in
                sysWords.contains { abs($0.start - mw.start) < 1.5 && Self.similar($0.text, mw.text) }
            }
            var drop = isEcho
            for turn in Self.speakerTurns(diar.segments) {
                let inside = micWords.indices.filter {
                    let mid = (micWords[$0].start + micWords[$0].end) / 2
                    return mid >= turn.start - 0.3 && mid <= turn.end + 0.5
                }
                let echoes = inside.filter { isEcho[$0] }.count
                if !inside.isEmpty, Double(echoes) / Double(inside.count) >= 0.4 {
                    for i in inside { drop[i] = true }
                }
            }
            micWords = micWords.indices.filter { !drop[$0] }.map { micWords[$0] }
            if before != micWords.count { log("Removi \(before - micWords.count) palavras de eco do mic") }
        }
        tagged += micWords.map { ($0, Self.meID) }
        tagged.sort { $0.0.start < $1.0.start }

        // Frases por falante (pausa < 1,2 s), depois em ordem de início; falas sobrepostas não se intercalam palavra a palavra.
        var runs: [(speaker: String, start: Double, end: Double, text: String)] = []
        var open: [String: Int] = [:]
        for (w, s) in tagged {
            if let i = open[s], w.start - runs[i].end < 1.2 {
                runs[i].text += " " + w.text
                runs[i].end = w.end
            } else {
                runs.append((s, w.start, w.end, w.text))
                open[s] = runs.count - 1
            }
        }
        runs.sort { $0.start < $1.start }
        var spans: [(speaker: String, start: Double, end: Double, text: String)] = []
        for r in runs {
            if let last = spans.last, last.speaker == r.speaker, r.start - last.end < 2 {
                spans[spans.count - 1].text += " " + r.text
                spans[spans.count - 1].end = max(last.end, r.end)
            } else {
                spans.append(r)
            }
        }

        // Primeiro sai a nota com o texto do Parakeet (rápido); o Cohere refina depois, em segundo plano (`refine`).
        let vocab = Vocabulary.load()
        let turns = spans.map { span in
            let text = vocab.apply(span.text)
            return CallTranscript.Turn(speaker: span.speaker, start: span.start,
                                       text: config.language == "pt" ? Numbers.normalize(text) : text, end: span.end)
        }
        let duration = Double(max(mic.count, sys.count)) / Audio.sampleRate
        var transcript = CallTranscript(id: dir.lastPathComponent, date: date, duration: duration,
                                        speakers: speakers, turns: turns)

        if config.summarizeWithClaude && !turns.isEmpty {
            log("Resumindo com o Claude…")
            do {
                let notes = Vault(config: config).noteNames()
                let raw = try await Claude.run(prompt: Claude.summaryPrompt,
                                               input: Self.catalog(notes) + Vocabulary.load().promptHint + Self.plainTranscript(transcript),
                                               claudePath: config.claudePath)
                let (withoutTitle, title) = Self.splitTitle(raw)
                let (withoutRelated, related) = Self.splitRelated(withoutTitle, notes: notes)
                let (summary, suggestions) = Self.splitSuggestions(withoutRelated)
                transcript.summary = summary
                transcript.related = related.isEmpty ? nil : related
                transcript.title = title
                transcript.suggestions = suggestions.isEmpty ? nil : suggestions
                for (who, s) in suggestions { log("\(who) parece ser \(s.name) (\(s.reason))") }
            } catch {
                log("Resumo indisponível: \(error.localizedDescription)")
            }
        }
        try save(transcript, in: dir)
        return transcript
    }

    /// Texto final com o Cohere (idioma fixo), trecho a trecho. Demora (~2 s por trecho), por isso roda depois da nota pronta.
    /// `pause` é consultado antes de cada trecho: enquanto devolver true (ditado ou call em andamento), espera.
    func refine(dir: URL, pause: @escaping () async -> Bool = { false }) async throws -> CallTranscript {
        let draft = try Self.load(dir: dir)
        let fm = FileManager.default
        let micURL = dir.appendingPathComponent("mic.wav"), sysURL = dir.appendingPathComponent("system.wav")
        let mic = fm.fileExists(atPath: micURL.path) ? try Audio.readWAV(micURL) : []
        let sys = fm.fileExists(atPath: sysURL.path) ? try Audio.readWAV(sysURL) : []
        var texts: [Int: String] = [:]
        for (i, turn) in draft.turns.enumerated() {
            guard let end = turn.end else { continue }
            while await pause() { try await Task.sleep(nanoseconds: 2_000_000_000) }
            let source = turn.speaker == Self.meID ? mic : sys
            let a = max(0, Int((turn.start - 0.3) * Audio.sampleRate))
            let b = min(source.count, Int((end + 0.4) * Audio.sampleRate))
            guard b > a else { continue }
            if let t = try? await transcriber.text(Array(source[a..<b]), language: config.language, draft: turn.text), !t.isEmpty {
                texts[i] = t
            }
        }
        // Relê do disco: os falantes podem ter sido nomeados enquanto o refino rodava.
        var t = try Self.load(dir: dir)
        guard t.turns.count == draft.turns.count else { return t }
        for i in t.turns.indices {
            if let text = texts[i] { t.turns[i].text = text }
            t.turns[i].end = nil
        }
        try save(t, in: dir)
        return t
    }

    func save(_ t: CallTranscript, in dir: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(t).write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
    }

    static func load(dir: URL) throws -> CallTranscript {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(CallTranscript.self, from: Data(contentsOf: dir.appendingPathComponent("transcript.json")))
    }

    // MARK: - Texto

    static func plainTranscript(_ t: CallTranscript) -> String {
        t.turns.map { "[\(timestamp($0.start))] \(t.label($0.speaker)): \($0.text)" }.joined(separator: "\n")
    }

    /// `notes`: nomes de link que existem no vault; participantes com nota viram link e links do resumo sem nota viram texto.
    static func markdown(_ t: CallTranscript, notes: Set<String> = []) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "pt_BR")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let human = DateFormatter()
        human.locale = Locale(identifier: "pt_BR")
        human.dateFormat = "dd/MM/yyyy 'às' HH:mm"
        let minutes = max(1, Int((t.duration / 60).rounded()))
        let names = t.speakers.map(\.label)
        var md = """
        ---
        tipo: call
        data: \(df.string(from: t.date))
        duracao_min: \(minutes)
        participantes: [\(names.map { "\"\($0)\"" }.joined(separator: ", "))]
        hermes_id: \(t.id)
        ---
        # \(t.title ?? "Call \(df.string(from: t.date))")

        > Gravado pelo Hermes · \(human.string(from: t.date)) · \(minutes) min · \(names.map { notes.contains($0) ? "[[\($0)]]" : $0 }.joined(separator: ", "))

        """
        let related = (t.related ?? []).filter { notes.isEmpty || notes.contains($0) }
        if !related.isEmpty { md += "> Relacionado: \(related.map { "[[\($0)]]" }.joined(separator: " · "))\n" }
        if let s = t.summary { md += "\n" + (notes.isEmpty ? s : unlinkMissing(s, notes: notes)) + "\n" }
        let unknown = t.speakers.filter { !$0.known && $0.embedding != nil }.map(\.label)
        if !unknown.isEmpty {
            md += "\n> [!info] Falantes não reconhecidos: \(unknown.joined(separator: ", ")). Nomeie pelo menu do Hermes → \"Nomear falantes da última call\" e eles serão reconhecidos nas próximas.\n"
            for label in unknown {
                if let s = t.suggestions?[label] { md += "> - \(label) parece ser **\(s.name)** — \(s.reason)\n" }
            }
        }
        md += "\n## Transcrição\n\n"
        for turn in t.turns {
            md += "**[\(timestamp(turn.start))] \(t.label(turn.speaker)):** \(turn.text)\n\n"
        }
        return md
    }

    static func timestamp(_ s: Double) -> String {
        let total = Int(s)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Tira as linhas "FALANTE: Pessoa N = Nome | indício" do resumo.
    static func splitSuggestions(_ raw: String) -> (String, [String: CallTranscript.Suggestion]) {
        var found: [String: CallTranscript.Suggestion] = [:]
        var kept: [String] = []
        for line in raw.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*", with: "")
            guard l.hasPrefix("FALANTE:") else { kept.append(line); continue }
            let body = l.dropFirst("FALANTE:".count)
            let parts = body.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let pair = parts[0].split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, !pair[1].isEmpty else { continue }
            found[pair[0]] = .init(name: pair[1], reason: parts.count > 1 ? parts[1] : "")
        }
        return (kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), found)
    }

    /// Lista de notas que vai antes da transcrição, para o Claude escolher os links.
    static func catalog(_ notes: Set<String>) -> String {
        guard !notes.isEmpty else { return "" }
        return "NOTAS DO VAULT:\n" + notes.sorted().map { "- \($0)" }.joined(separator: "\n") + "\n\nTRANSCRIÇÃO:\n"
    }

    /// Tira a linha "RELACIONADO: a; b" e fica só com o que existe no vault (sem nota fantasma no graph).
    static func splitRelated(_ raw: String, notes: Set<String>) -> (String, [String]) {
        var lines = raw.components(separatedBy: "\n")
        guard let i = lines.lastIndex(where: { $0.replacingOccurrences(of: "*", with: "").hasPrefix("RELACIONADO:") }) else { return (raw, []) }
        let body = lines[i].replacingOccurrences(of: "*", with: "").dropFirst("RELACIONADO:".count)
        lines.remove(at: i)
        let lower = Dictionary(notes.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var found: [String] = []
        for part in body.split(whereSeparator: { $0 == ";" || $0 == "," }) {
            let name = part.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if let real = lower[name.lowercased()], !found.contains(real) { found.append(real) }
        }
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), found)
    }

    /// `[[x]]` sem nota no vault vira texto puro.
    static func unlinkMissing(_ s: String, notes: Set<String>) -> String {
        let re = try! NSRegularExpression(pattern: #"\[\[([^\]|#]+)(?:[|#][^\]]*)?\]\]"#)
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(m.range, in: s), let inner = Range(m.range(at: 1), in: s) else { continue }
            let name = String(s[inner]).trimmingCharacters(in: .whitespaces)
            if !notes.contains(name) { out.replaceSubrange(whole, with: name) }
        }
        return out
    }

    static func splitTitle(_ raw: String) -> (String, String?) {
        var lines = raw.components(separatedBy: "\n")
        guard let i = lines.lastIndex(where: { $0.hasPrefix("TITULO:") }) else { return (raw, nil) }
        let title = lines[i].dropFirst("TITULO:".count).trimmingCharacters(in: .whitespaces)
        lines.remove(at: i)
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), title.isEmpty ? nil : title)
    }

    /// Junta segmentos consecutivos do mesmo falante (pausas < 1 s) e corta turnos longos em ~60 s.
    static func speakerTurns(_ segments: [TimedSpeakerSegment]) -> [(start: Double, end: Double)] {
        var turns: [(id: String, start: Double, end: Double)] = []
        for s in segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            let start = Double(s.startTimeSeconds), end = Double(s.endTimeSeconds)
            if let last = turns.last, last.id == s.speakerId, start - last.end < 1, end - last.start < 60 {
                turns[turns.count - 1].end = max(last.end, end)
            } else {
                turns.append((s.speakerId, start, end))
            }
        }
        return turns.map { ($0.start, $0.end) }
    }

    /// Palavras "parecidas": iguais, uma é prefixo da outra (≥ 3 letras) ou distância de edição ≤ 40%.
    static func similar(_ a: String, _ b: String) -> Bool {
        let x = Array(core(a).folding(options: .diacriticInsensitive, locale: nil))
        let y = Array(core(b).folding(options: .diacriticInsensitive, locale: nil))
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        if min(x.count, y.count) >= 3 && (x.starts(with: y) || y.starts(with: x)) { return true }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + [Int](repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return Double(prev[y.count]) / Double(max(x.count, y.count)) <= 0.4
    }

    static func core(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }

    static func meanEmbedding(_ list: [[Float]]) -> [Float] {
        guard let first = list.first else { return [] }
        var acc = [Float](repeating: 0, count: first.count)
        for e in list where e.count == acc.count { for i in 0..<e.count { acc[i] += e[i] } }
        return acc.map { $0 / Float(list.count) }
    }
}
