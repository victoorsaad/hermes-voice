import AVFoundation
import CoreAudio

/// Grava tudo o que o Mac toca (Zoom, Meet, Slack…) via Core Audio process tap (macOS 14.2+).
/// Não precisa de driver virtual; o macOS pede a permissão "Gravação de áudio do sistema" no 1º uso.
final class SystemAudioRecorder {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "hermes.systemaudio", qos: .userInitiated)
    private let lock = NSLock()
    private var samples: [Float] = []
    // Fones Bluetooth (AirPods) caem para 16/24 kHz quando a call abre o mic, sem o tap avisar.
    // A taxa real é medida pelo relógio: amostras por segundo em janelas de ~1 s, convertidas só depois de medidas.
    private var rate: Double = 48_000
    private var converter: AVAudioConverter?
    private var window: [Float] = []
    private var windowStart: UInt64 = 0
    private static let ticksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e9 * Double(info.denom) / Double(info.numer)
    }()
    private static let standardRates: [Double] = [8_000, 11_025, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 88_200, 96_000]

    func start() throws {
        lock.withLock { samples.removeAll(keepingCapacity: true) }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "Hermes"
        try check(AudioHardwareCreateProcessTap(description, &tapID), "criar o tap de áudio")

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "ler o formato do tap")
        rate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        converter = Self.makeConverter(rate)
        window.removeAll()
        windowStart = 0
        let channels = Int(max(format.mChannelsPerFrame, 1))

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Hermes Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "criar o dispositivo agregado")

        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, inputTime, _, _ in
            self?.consume(input, at: inputTime.pointee.mHostTime, channels: channels, nonInterleaved: nonInterleaved)
        }, "registrar o callback de áudio")
        try check(AudioDeviceStart(aggregateID, procID), "iniciar a captura")
    }

    /// Amostras já captadas (16 kHz), para transcrever ao vivo sem parar a gravação.
    var count: Int { lock.withLock { samples.count } }

    func samples(from start: Int) -> [Float] {
        lock.withLock { start < samples.count ? Array(samples[max(0, start)...]) : [] }
    }

    /// Para a captura e devolve mono 16 kHz.
    func stop() -> [Float] {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        queue.sync { flushWindow(now: mach_absolute_time()) }
        aggregateID = kAudioObjectUnknown
        tapID = kAudioObjectUnknown
        procID = nil
        return lock.withLock { samples }
    }

    private func consume(_ list: UnsafePointer<AudioBufferList>, at hostTime: UInt64, channels: Int, nonInterleaved: Bool) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, let data = first.mData else { return }
        var mono: [Float]
        if nonInterleaved {
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            mono = [Float](repeating: 0, count: frames)
            for buf in buffers {
                guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<frames { mono[i] += p[i] / Float(buffers.count) }
            }
        } else {
            let p = data.assumingMemoryBound(to: Float.self)
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
            mono = [Float](repeating: 0, count: frames)
            for i in 0..<frames {
                var s: Float = 0
                for c in 0..<channels { s += p[i * channels + c] }
                mono[i] = s / Float(channels)
            }
        }
        let now = hostTime > 0 ? hostTime : mach_absolute_time()
        if windowStart == 0 { windowStart = now }
        window.append(contentsOf: mono)
        if Double(now - windowStart) / Self.ticksPerSecond >= 1 { flushWindow(now: now) }
    }

    /// Fecha a janela: mede a taxa real, troca o conversor se mudou e guarda o trecho em 16 kHz.
    private func flushWindow(now: UInt64) {
        guard !window.isEmpty else { return }
        let seconds = Double(now - windowStart) / Self.ticksPerSecond
        if seconds >= 0.5 {
            let measured = Double(window.count) / seconds
            if let snapped = Self.standardRates.min(by: { abs($0 - measured) < abs($1 - measured) }),
               abs(snapped - measured) / snapped < 0.08, snapped != rate {
                NSLog("Hermes: áudio do sistema mudou de %.0f para %.0f Hz", rate, snapped)
                rate = snapped
                converter = Self.makeConverter(snapped)
            }
        }
        // Reamostra já na captura: 1 h de call ocupa ~230 MB em vez de ~700 MB.
        if let converter, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
           let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(window.count)) {
            buf.frameLength = AVAudioFrameCount(window.count)
            window.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: window.count) }
            let chunk = Audio.convert(buf, with: converter, to: Audio.format16k)
            lock.withLock { samples.append(contentsOf: chunk) }
        }
        window.removeAll(keepingCapacity: true)
        windowStart = now
    }

    private static func makeConverter(_ rate: Double) -> AVAudioConverter? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
            .flatMap { AVAudioConverter(from: $0, to: Audio.format16k) }
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            throw HermesError("Sem dispositivo de saída de áudio")
        }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else {
            throw HermesError("Não consegui ler o UID da saída de áudio")
        }
        return uid.takeRetainedValue() as String
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw HermesError("Falha ao \(what) (OSStatus \(status))") }
    }
}
