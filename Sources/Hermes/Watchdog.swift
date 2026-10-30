import Foundation

/// Se a thread principal parar de responder por 20 s (o atalho morre junto), registra e reabre o Hermes sozinho.
/// Durante uma call não reabre: perderia a gravação.
enum MainWatchdog {
    private static let beat = Beat()

    static func start(recordingCall: @escaping @MainActor () -> Bool) {
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { beat.set(Date(), call: recordingCall()) }
        }
        RunLoop.main.add(timer, forMode: .common)
        Thread.detachNewThread {
            var warned = false
            var lastLoop = Date()
            while true {
                Thread.sleep(forTimeInterval: 2)
                // O Mac dormiu (esta thread também parou): não é travamento.
                if Date().timeIntervalSince(lastLoop) > 10 { beat.set(Date(), call: beat.get().1) }
                lastLoop = Date()
                let (last, call) = beat.get()
                let stuck = Date().timeIntervalSince(last)
                if stuck > 5, !warned { Log.write(String(format: "app travado há %.0f s", stuck)); warned = true }
                if stuck < 5 { warned = false }
                if stuck > 20, !call {
                    Log.write("app travado há 20 s: reabrindo")
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/bin/sh")
                    p.arguments = ["-c", "sleep 2; open '\(Bundle.main.bundlePath)'"]
                    try? p.run()
                    _exit(1)
                }
            }
        }
    }

    private final class Beat: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date()
        private var call = false
        func set(_ d: Date, call c: Bool) { lock.withLock { last = d; call = c } }
        func get() -> (Date, Bool) { lock.withLock { (last, call) } }
    }
}

/// Resultado de `work`, ou nil se passar de `seconds`.
func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); return nil }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
