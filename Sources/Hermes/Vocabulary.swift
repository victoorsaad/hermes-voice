import Foundation

/// Vocabulário próprio em ~/Library/Application Support/Hermes/vocabulary.txt.
/// O Cohere não aceita lista de palavras, então a correção é feita depois: trechos parecidos com um termo
/// (mesma inicial, ≥ 75–80% iguais, juntando até uma palavra a mais: "Super Base" → "Supabase") viram o termo.
/// Linhas "errado -> certo" trocam sempre. Os nomes dos perfis de voz entram automaticamente.
struct Vocabulary {
    private(set) var terms: [String] = []
    private(set) var replacements: [(from: String, to: String)] = []

    static let file = Config.dataDir.appendingPathComponent("vocabulary.txt")

    private static let template = """
    # Vocabulário do Hermes: uma palavra, nome ou expressão por linha.
    # Variações parecidas na transcrição viram a grafia daqui (ex.: "Super Base" → "Supabase").
    # Para uma troca fixa use: errado -> certo
    # Linhas com # são ignoradas. Nomes salvos em "Nomear falantes" entram sozinhos.

    Hermes
    Claude Code
    Obsidian
    Notion
    Slack
    GitHub
    deploy

    # Trocas fixas (palavras curtas demais para a correção automática)
    # Clod -> Claude
    """

    private static var cache: (date: Date, vocab: Vocabulary)?
    private static let lock = NSLock()

    /// Lê o arquivo (cria com o modelo na 1ª vez); relê só quando o arquivo muda.
    static func load() -> Vocabulary {
        lock.withLock {
            let fm = FileManager.default
            if !fm.fileExists(atPath: file.path) { try? template.write(to: file, atomically: true, encoding: .utf8) }
            let date = (try? fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? .distantPast
            let profiles = SpeakerProfiles.load().profiles.map(\.name)
            if let cache, cache.date == date, Set(profiles).isSubset(of: cache.vocab.terms) { return cache.vocab }
            var v = Vocabulary(text: (try? String(contentsOf: file, encoding: .utf8)) ?? "")
            for name in profiles where !v.terms.contains(name) { v.terms.append(name) }
            cache = (date, v)
            return v
        }
    }

    /// Termos e trocas escritos pelo usuário (sem os nomes automáticos dos perfis).
    static func userEntries() -> (terms: [String], replacements: [(from: String, to: String)]) {
        _ = load()
        let v = Vocabulary(text: (try? String(contentsOf: file, encoding: .utf8)) ?? "")
        return (v.terms, v.replacements)
    }

    static func save(terms: [String], replacements: [(from: String, to: String)]) {
        let header = template.components(separatedBy: "\n").prefix(4).joined(separator: "\n")
        var text = header + "\n\n" + terms.joined(separator: "\n") + "\n"
        if !replacements.isEmpty {
            text += "\n# Trocas fixas\n" + replacements.map { "\($0.from) -> \($0.to)" }.joined(separator: "\n") + "\n"
        }
        lock.withLock { try? text.write(to: file, atomically: true, encoding: .utf8) }
    }

    init(text: String) {
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if let r = line.range(of: "->") {
                let from = line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                let to = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if !from.isEmpty { replacements.append((from, to)) }
            } else {
                terms.append(line)
            }
        }
    }

    /// Para o Claude grafar certo no resumo e no chat.
    var promptHint: String {
        terms.isEmpty ? "" : "Grafia correta de nomes e termos: \(terms.joined(separator: ", ")).\n\n"
    }

    func apply(_ text: String) -> String {
        var out = text
        for r in replacements {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: r.from) + "(?![\\p{L}\\p{N}])"
            out = out.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: r.to),
                                           options: [.regularExpression, .caseInsensitive])
        }
        return fuzzy(out)
    }

    private func fuzzy(_ text: String) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { return text }
        // Termos longos primeiro: "Claude Code" antes de "Claude".
        for term in terms.sorted(by: { $0.count > $1.count }) {
            let key = Self.key(term)
            let n = term.split(separator: " ").count
            guard key.count >= 4 else { continue }
            var i = 0
            while i < words.count {
                for k in [n, n + 1] where i + k <= words.count {
                    let window = Array(words[i..<i + k])
                    let candidate = Self.key(window.joined())
                    guard candidate.first == key.first, Self.similarity(candidate, key) >= (key.count >= 6 ? 0.75 : 0.8) else { continue }
                    let joined = window.joined(separator: " ")
                    if joined.trimmingCharacters(in: .punctuationCharacters) == term { break }
                    // Mantém pontuação colada no fim ("Supabeis," → "Supabase,").
                    let trailing = String(window.last!.reversed().prefix { $0.isPunctuation }.reversed())
                    let leading = String(window.first!.prefix { $0.isPunctuation })
                    words.replaceSubrange(i..<i + k, with: [leading + term + trailing])
                    break
                }
                i += 1
            }
        }
        return words.joined(separator: " ")
    }

    /// Minúsculas, sem acento, só letras e números.
    static func key(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + [Int](repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }
}
