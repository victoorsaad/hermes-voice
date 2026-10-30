import Foundation

/// Perfis de voz salvos: nome → embedding médio (256-d, WeSpeaker). Em ~/Library/Application Support/Hermes/speakers.json.
struct SpeakerProfiles: Codable {
    struct Profile: Codable {
        var name: String
        var embedding: [Float]
        var samples: Int
    }

    var profiles: [Profile] = []

    private static var file: URL { Config.dataDir.appendingPathComponent("speakers.json") }

    static func load() -> SpeakerProfiles {
        guard let data = try? Data(contentsOf: file),
              let p = try? JSONDecoder().decode(SpeakerProfiles.self, from: data) else { return SpeakerProfiles() }
        return p
    }

    func save() {
        try? JSONEncoder().encode(self).write(to: Self.file, options: .atomic)
    }

    /// Melhor perfil acima do limiar, se houver.
    func match(_ embedding: [Float], threshold: Float) -> (name: String, score: Float)? {
        let best = profiles
            .map { ($0.name, Self.cosine($0.embedding, embedding)) }
            .max { $0.1 < $1.1 }
        guard let best, best.1 >= threshold else { return nil }
        return best
    }

    /// Cadastra ou reforça um perfil (média móvel ponderada pelo nº de amostras).
    mutating func enroll(name: String, embedding: [Float]) {
        let e = Self.normalized(embedding)
        if let i = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            let n = Float(profiles[i].samples)
            let merged = zip(profiles[i].embedding, e).map { ($0 * n + $1) / (n + 1) }
            profiles[i].embedding = Self.normalized(merged)
            profiles[i].samples += 1
        } else {
            profiles.append(Profile(name: name, embedding: e, samples: 1))
        }
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let d = (na * nb).squareRoot()
        return d > 0 ? dot / d : 0
    }
}
