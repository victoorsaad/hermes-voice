import Foundation

/// Pausa o que estiver tocando (Spotify, Music, YouTube…) durante o ditado e retoma depois.
/// Usa o comando de mídia do sistema (MediaRemote), o mesmo da tecla ⏯; só pausa se algo já estiver tocando.
enum Media {
    private static let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)

    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool
    private typealias IsPlaying = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    private static let send: SendCommand? = handle.flatMap { dlsym($0, "MRMediaRemoteSendCommand") }.map { unsafeBitCast($0, to: SendCommand.self) }
    private static let isPlaying: IsPlaying? = handle.flatMap { dlsym($0, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") }.map { unsafeBitCast($0, to: IsPlaying.self) }
    private static let play: UInt32 = 0, pause: UInt32 = 1

    /// Pausa só se o sistema confirmar que há mídia tocando agora. Devolve true se pausou (para retomar depois).
    /// Na dúvida não faz nada: mandar "play" sem nada pausado abre o Música ou solta um vídeo que estava parado.
    static func pauseIfPlaying() -> Bool {
        guard let send, nowPlaying() else { return false }
        return send(pause, nil)
    }

    static func resume() {
        _ = send?(play, nil)
    }

    /// Pergunta ao MediaRemote se o app de mídia atual está tocando (espera no máximo 0,3 s).
    private static func nowPlaying() -> Bool {
        guard let isPlaying else { return false }
        let done = DispatchSemaphore(value: 0)
        let result = Locked(false)
        isPlaying(DispatchQueue.global()) { playing in
            result.set(playing)
            done.signal()
        }
        return done.wait(timeout: .now() + 0.3) == .success && result.get()
    }
}

private final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}

extension Audio {
    /// Lê qualquer áudio ou vídeo (m4a, mp3, opus do WhatsApp, mp4, mov…) como mono 16 kHz.
    /// Tenta o AVFoundation; se não abrir, usa o ffmpeg do Homebrew.
    static func readAny(_ url: URL) throws -> [Float] {
        if let samples = try? readWAV(url), !samples.isEmpty { return samples }
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let ffmpeg else { throw HermesError("Formato não suportado (instale o ffmpeg: brew install ffmpeg)") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-nostdin", "-v", "error", "-i", url.path, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", tmp.path]
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw HermesError("ffmpeg não conseguiu ler \(url.lastPathComponent)") }
        return try readWAV(tmp)
    }
}
