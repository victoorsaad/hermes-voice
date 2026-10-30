import AppKit
import AVFoundation
import SwiftUI

/// Últimos ditados em history.json, para recuperar o que não colou.
struct DictationEntry: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var text: String
    var mode: String
    var app: String
    /// Áudio do ditado (AAC) em dictations/<id>.m4a, para ouvir de novo ou reprocessar.
    var audio: String?
    /// Texto antes do polimento (o que a transcrição ouviu).
    var raw: String?

    var audioURL: URL? { audio.map { History.audioDir.appendingPathComponent($0) } }
}

@MainActor
final class History: ObservableObject {
    @Published private(set) var entries: [DictationEntry] = []
    private let file = Config.dataDir.appendingPathComponent("history.json")
    private let limit = 300

    init() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        entries = (try? dec.decode([DictationEntry].self, from: Data(contentsOf: file))) ?? []
    }

    static let audioDir = Config.dataDir.appendingPathComponent("dictations", isDirectory: true)

    @discardableResult
    func add(_ text: String, mode: String, app: String, samples: [Float]? = nil, raw: String? = nil) -> UUID {
        var entry = DictationEntry(date: Date(), text: text, mode: mode, app: app, raw: raw == text ? nil : raw)
        if let samples, !samples.isEmpty {
            let name = "\(entry.id.uuidString).m4a"
            entry.audio = name
            Task.detached { try? Self.writeAAC(samples, to: Self.audioDir.appendingPathComponent(name)) }
        }
        entries.insert(entry, at: 0)
        while entries.count > limit { removeAudio(entries.removeLast()) }
        persist()
        return entry.id
    }

    func delete(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        removeAudio(entries.remove(at: i))
        persist()
    }

    func update(_ id: UUID, text: String, mode: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        if entries[i].raw == nil { entries[i].raw = entries[i].text }
        entries[i].text = text
        entries[i].mode = mode
        persist()
    }

    private func removeAudio(_ e: DictationEntry) {
        if let url = e.audioURL { try? FileManager.default.removeItem(at: url) }
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(entries).write(to: file, options: .atomic)
    }

    /// Mono 16 kHz → AAC 32 kbps (~4 KB por segundo de fala).
    nonisolated static func writeAAC(_ samples: [Float], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: Audio.sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Audio.sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000,
        ])
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }

    /// Lê o áudio salvo de volta (para reprocessar).
    nonisolated static func readAudio(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        return file.processingFormat.sampleRate == Audio.sampleRate ? samples : Audio.resample(samples, from: file.processingFormat.sampleRate)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Toca um áudio de cada vez (o do ditado clicado).
@MainActor
final class Player: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playing: UUID?
    private var player: AVAudioPlayer?

    func toggle(_ e: DictationEntry) {
        if playing == e.id { stop(); return }
        guard let url = e.audioURL, let p = try? AVAudioPlayer(contentsOf: url) else { return }
        player = p
        p.delegate = self
        p.play()
        playing = e.id
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

struct HistoryView: View {
    @ObservedObject var history: History
    /// Reprocessa o áudio salvo com outro modo (nil = mesmo modo, só transcreve de novo).
    var onRedo: ((DictationEntry, DictationMode?) -> Void)?
    @ObservedObject private var store = ModeStore.shared
    @StateObject private var player = Player()
    @State private var query = ""
    @State private var copied: UUID?

    private var filtered: [DictationEntry] {
        query.isEmpty ? history.entries : history.entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Buscar", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            if filtered.isEmpty {
                Spacer()
                Text(history.entries.isEmpty ? "Nenhum ditado ainda. Segure ⌥ direito e fale." : "Nada encontrado")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filtered) { e in
                    HStack(alignment: .top, spacing: 10) {
                        Button { player.toggle(e) } label: {
                            Image(systemName: player.playing == e.id ? "stop.circle.fill" : "play.circle.fill").font(.title2)
                        }
                        .buttonStyle(.borderless)
                        .disabled(e.audioURL.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true)
                        .help(e.audio == nil ? "Ditados antigos não têm áudio salvo" : "Ouvir")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(e.text).textSelection(.enabled).lineLimit(6)
                            Text("\(e.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "pt_BR")))), \(e.mode)\(e.app.isEmpty ? "" : ", \(e.app)")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let onRedo, e.audio != nil {
                            Menu {
                                Button("Transcrever de novo") { onRedo(e, nil) }
                                Divider()
                                ForEach(store.modes) { m in Button("Refazer como \(m.name)") { onRedo(e, m) } }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            } primaryAction: {
                                onRedo(e, nil)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Regenerar: clique para transcrever de novo; a setinha escolhe outro modo")
                        }
                        Button(copied == e.id ? "Copiado" : "Copiar") {
                            History.copy(e.text)
                            copied = e.id
                        }
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        Button("Copiar") { History.copy(e.text) }
                        if let raw = e.raw { Button("Copiar sem polimento") { History.copy(raw) } }
                        if let onRedo, e.audio != nil {
                            Divider()
                            Button("Transcrever de novo") { onRedo(e, nil) }
                            Menu("Refazer como") {
                                ForEach(store.modes) { m in Button(m.name) { onRedo(e, m) } }
                            }
                        }
                        Divider()
                        Button("Excluir", role: .destructive) { history.delete(e.id) }
                    }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 360)
        .onDisappear { player.stop() }
    }
}
