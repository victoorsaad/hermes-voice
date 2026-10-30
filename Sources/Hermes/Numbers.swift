import Foundation

/// Números por extenso → algarismos, em português, sem IA.
/// "dois mil e vinte e seis" → 2026, "vinte e cinco reais" → R$ 25, "dez por cento" → 10%, "vinte e três de outubro" → 23 de outubro.
/// Números pequenos sozinhos ("uma call", "dois minutos") ficam por extenso, como se escreve.
enum Numbers {
    private static let units: [String: Int] = [
        "zero": 0, "um": 1, "uma": 1, "dois": 2, "duas": 2, "três": 3, "tres": 3, "quatro": 4, "cinco": 5, "seis": 6, "sete": 7,
        "oito": 8, "nove": 9, "dez": 10, "onze": 11, "doze": 12, "treze": 13, "catorze": 14, "quatorze": 14, "quinze": 15,
        "dezesseis": 16, "dezessete": 17, "dezoito": 18, "dezenove": 19, "vinte": 20, "trinta": 30, "quarenta": 40,
        "cinquenta": 50, "sessenta": 60, "setenta": 70, "oitenta": 80, "noventa": 90, "cem": 100, "cento": 100,
        "duzentos": 200, "duzentas": 200, "trezentos": 300, "trezentas": 300, "quatrocentos": 400, "quatrocentas": 400,
        "quinhentos": 500, "quinhentas": 500, "seiscentos": 600, "seiscentas": 600, "setecentos": 700, "setecentas": 700,
        "oitocentos": 800, "oitocentas": 800, "novecentos": 900, "novecentas": 900,
    ]
    private static let scales: [String: Int] = ["mil": 1000, "milhão": 1_000_000, "milhões": 1_000_000, "bilhão": 1_000_000_000, "bilhões": 1_000_000_000]
    private static let months = ["janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro", "novembro", "dezembro"]

    static func normalize(_ text: String) -> String {
        // Tokens com a pontuação separada, para remontar depois.
        let tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            guard let (value, used, trailing) = parse(tokens, from: i) else { out.append(tokens[i]); i += 1; continue }
            let next = i + used < tokens.count ? clean(tokens[i + used]) : ""
            let next2 = i + used + 1 < tokens.count ? clean(tokens[i + used + 1]) : ""
            let isMoney = trailing.isEmpty && (next == "reais" || next == "real")
            let isPercent = trailing.isEmpty && next == "por" && next2 == "cento"
            let isDate = trailing.isEmpty && next == "de" && months.contains(next2)
            let isBig = value >= 10 || used > 1
            guard isMoney || isPercent || isDate || isBig else { out.append(tokens[i]); i += 1; continue }
            let digits = format(value, year: !isMoney)
            let lead = leadingPunct(tokens[i])
            if isMoney {
                let after = tokens[i + used]
                out.append(lead + "R$ " + digits + String(after.drop { $0.isLetter }))
                i += used + 1
            } else if isPercent {
                let after = tokens[i + used + 1]
                out.append(lead + digits + "%" + String(after.drop { $0.isLetter }))
                i += used + 2
            } else {
                out.append(lead + digits + trailing)
                i += used
            }
        }
        return out.joined(separator: " ")
    }

    /// Lê a maior sequência numérica a partir de `start`. Devolve valor, tokens usados e a pontuação final.
    private static func parse(_ tokens: [String], from start: Int) -> (Int, Int, String)? {
        var total = 0, current = 0, used = 0, lastWasNumber = false, best: (Int, Int, String)?
        var j = start
        while j < tokens.count {
            let raw = tokens[j]
            let word = clean(raw)
            let trailing = String(raw.reversed().prefix { !$0.isLetter }.reversed())
            if word == "e", lastWasNumber, j + 1 < tokens.count, units[clean(tokens[j + 1])] != nil, trailingPunct(raw).isEmpty {
                lastWasNumber = false
                j += 1
                continue
            }
            if let u = units[word] {
                // "vinte três" sem "e" ou dois números seguidos: para (ex.: "um dois três" é contagem).
                if lastWasNumber, current % 10 != 0 || current == 0 || u >= current { break }
                current += u
            } else if let sc = scales[word], current > 0 || word == "mil" {
                if current == 0 { current = 1 }
                if sc == 1000 { total += current * 1000 } else { total += current * sc }
                current = 0
            } else {
                break
            }
            lastWasNumber = true
            used = j - start + 1
            best = (total + current, used, trailing)
            if !trailing.isEmpty { break }
            j += 1
        }
        return best
    }

    private static func clean(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    private static func trailingPunct(_ s: String) -> String {
        String(s.reversed().prefix { !$0.isLetter }.reversed())
    }

    private static func leadingPunct(_ s: String) -> String {
        String(s.prefix { !$0.isLetter })
    }

    /// 2026 (ano) sem ponto; 2.500 e 1.000.000 com ponto.
    private static func format(_ n: Int, year: Bool) -> String {
        if year, (1900...2100).contains(n) { return String(n) }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "pt_BR")
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }
}
