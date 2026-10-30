import CoreAudio
import AVFoundation

/// Captura o microfone e entrega amostras mono 16 kHz Float32, o formato que o Parakeet espera.
/// Se o dispositivo de entrada mudar no meio (AirPods conectando, outro app mexendo no áudio), o AVAudioEngine para
/// sozinho: aqui ele é religado com o formato novo e a gravação continua, sem perder o que já foi captado.
final class Recorder {
    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private let target = Audio.format16k
    private var lastLevel: Float = 0
    private var converter: AVAudioConverter?
    private var running = false
    private var configObserver: NSObjectProtocol?
    private var watchdog: Timer?
    private var lastCount = 0
    private var stalledSince: Date?
    private var engineStartedAt = Date()
    /// Amostras recebidas desde o início (inclui a janela ainda não passada para `samples`).
    private var received = 0
    // Janela de ~1 s para medir a taxa real pelo relógio do áudio (AirPods às vezes entregam a metade do anunciado).
    private var window: [Float] = []
    private var windowStart: UInt64?
    private var lastRatio = 1.0

    /// RMS do último bloco captado (para o medidor do HUD).
    var level: Float { lock.withLock { lastLevel } }

    func start() throws {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            window.removeAll()
            windowStart = nil
            lastRatio = 1
            received = 0
        }
        running = true
        try startEngine()
        // Rede de segurança: se as amostras pararem de chegar por 1,5 s com o engine "rodando", religa.
        lastCount = 0
        stalledSince = nil
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkStall() }
    }

    /// Sempre um AVAudioEngine novo: o antigo guarda o formato de antes da troca (AirPods passam de 48 kHz para 24 kHz
    /// quando o mic liga) e aí o tap não recebe nada.
    private func startEngine() throws {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart(reason: "dispositivo de áudio mudou")
        }
        engineStartedAt = Date()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, let conv = AVAudioConverter(from: inFormat, to: target) else {
            throw HermesError("Formato do microfone não suportado")
        }
        lock.withLock { converter = conv }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, when in
            self?.append(buffer, at: when)
        }
        engine.prepare()
        try engine.start()
        Log.write("mic: \(Self.inputName()) a \(Int(inFormat.sampleRate)) Hz")
    }

    private func restart(reason: String) {
        guard running else { return }
        Log.write("mic: religando (\(reason)), \(count / Int(Audio.sampleRate)) s já gravados")
        do { try startEngine() } catch { Log.write("mic: falhou ao religar: \(error.localizedDescription)") }
    }

    private func checkStall() {
        let n = lock.withLock { received }
        if n != lastCount { lastCount = n; stalledSince = nil; return }
        if stalledSince == nil { stalledSince = Date(); return }
        // Bluetooth leva uns segundos para entregar o primeiro áudio depois de ligar: não religar antes disso.
        let grace = n == 0 ? 4.0 : 1.5
        if let since = stalledSince, Date().timeIntervalSince(since) > 1.5, Date().timeIntervalSince(engineStartedAt) > grace {
            stalledSince = nil
            restart(reason: "sem áudio chegando")
        }
    }

    /// Amostras já captadas (16 kHz), para transcrever ao vivo sem parar a gravação.
    var count: Int { lock.withLock { samples.count } }

    func samples(from start: Int) -> [Float] {
        lock.withLock { start < samples.count ? Array(samples[max(0, start)...]) : [] }
    }

    /// Vazio se nem chegou a ligar (soltou o ⌥ antes do mic), para não devolver o ditado anterior.
    func stop() -> [Float] {
        guard running else { return [] }
        running = false
        watchdog?.invalidate()
        watchdog = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        return lock.withLock {
            flushWindow(ratio: lastRatio)
            return samples
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        // Formato do buffer diferente do conversor (troca de dispositivo antes da notificação): refaz o conversor.
        var conv = lock.withLock { converter }
        if conv?.inputFormat != buffer.format {
            conv = AVAudioConverter(from: buffer.format, to: target)
            lock.withLock { converter = conv }
        }
        guard let conv else { return }
        let chunk = Audio.convert(buffer, with: conv, to: target)
        let rms = Audio.rms(chunk[...])
        lock.withLock {
            lastLevel = rms
            received += chunk.count
            guard when.isHostTimeValid else { samples.append(contentsOf: chunk); return }
            if let start = windowStart {
                let elapsed = AVAudioTime.seconds(forHostTime: when.hostTime) - AVAudioTime.seconds(forHostTime: start)
                if elapsed >= 1 {
                    // Quantas amostras deveriam ter chegado nesse tempo vs. quantas chegaram.
                    let ratio = elapsed * Audio.sampleRate / Double(max(window.count, 1))
                    lastRatio = abs(ratio - 1) > 0.08 && ratio > 0.3 && ratio < 4 ? ratio : 1
                    flushWindow(ratio: lastRatio)
                    windowStart = when.hostTime
                }
            } else {
                windowStart = when.hostTime
            }
            window.append(contentsOf: chunk)
        }
    }

    /// Passa a janela para as amostras, corrigindo a velocidade se a taxa real for outra. Chamar com o lock.
    private func flushWindow(ratio: Double) {
        guard !window.isEmpty else { return }
        if ratio != 1 {
            if !loggedRatio { Log.write(String(format: "mic: taxa real %.2f× a anunciada, corrigindo", ratio)); loggedRatio = true }
            samples.append(contentsOf: Audio.resample(window, from: Audio.sampleRate / ratio))
        } else {
            samples.append(contentsOf: window)
        }
        window.removeAll(keepingCapacity: true)
    }
    private var loggedRatio = false

    private static func inputName() -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr else { return "?" }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &name) == noErr, let name else { return "?" }
        return name.takeRetainedValue() as String
    }
}

struct HermesError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

enum Audio {
    static let sampleRate = 16_000.0
    static let format16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    /// Converte um buffer de entrada (qualquer taxa/canais) para o formato de destino.
    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to target: AVAudioFormat) -> [Float] {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ch = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }

    /// Reamostra um sinal mono inteiro (usado no áudio do sistema, capturado na taxa do dispositivo).
    static func resample(_ samples: [Float], from rate: Double) -> [Float] {
        if rate == sampleRate || samples.isEmpty { return samples }
        let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: inFormat, to: format16k) else { return [] }
        var result: [Float] = []
        result.reserveCapacity(Int(Double(samples.count) * sampleRate / rate) + 1024)
        let block = Int(rate) * 10
        var offset = 0
        while offset < samples.count {
            let n = min(block, samples.count - offset)
            guard let buf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(n)) else { break }
            buf.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { src in
                buf.floatChannelData![0].update(from: src.baseAddress! + offset, count: n)
            }
            result.append(contentsOf: convert(buf, with: converter, to: format16k))
            offset += n
        }
        return result
    }

    static func writeWAV(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 16_000 * 30
        var offset = 0
        while offset < samples.count {
            let n = min(chunk, samples.count - offset)
            let buf = AVAudioPCMBuffer(pcmFormat: format16k, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { src in
                buf.floatChannelData![0].update(from: src.baseAddress! + offset, count: n)
            }
            try file.write(from: buf)
            offset += n
        }
    }

    static func readWAV(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw HermesError("Não consegui ler \(url.lastPathComponent)")
        }
        try file.read(into: buf)
        let channels = Int(file.processingFormat.channelCount)
        let n = Int(buf.frameLength)
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<channels {
            let p = buf.floatChannelData![c]
            for i in 0..<n { mono[i] += p[i] / Float(channels) }
        }
        return resample(mono, from: file.processingFormat.sampleRate)
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}
