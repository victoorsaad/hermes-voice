import AppKit
import ServiceManagement
import AVFoundation
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

/// Hermes — dois cenários separados:
/// - Ditado (⌥ direito): segure para falar ou toque uma vez para mãos livres; o texto é colado no app em foco. Nunca vai para as notas.
/// - Call (⌥⌘R ou sugestão automática quando um app de reunião usa o mic): grava mic + sistema e vira nota (Markdown ou Notion).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = Recorder()
    private let transcriber = Transcriber()
    private var config = Config.load()
    private var monitors: [Any] = []
    private let hud = HUD()
    private var meterTimer: Timer?
    private var callHotKey: HotKey?
    private var detector: CallDetector?

    // Ditado
    private var dictating = false
    /// Muda a cada ditado: o mic liga um instante depois da pílula e só se ainda for o mesmo ditado.
    private var dictationToken = UUID()
    private var handsFree = false
    private var pressedAt: TimeInterval = 0
    private var ignoreRelease = false
    private var mode = ModeStore.shared.fallback
    private var targetApp = ""
    private var liveTask: Task<LiveSegmenter, Never>?
    private let liveCall = LiveCall()
    private var liveCallTask: Task<Void, Never>?
    private var liveWindow: NSPanel?
    private let history = History()
    private var mainWindow: NSWindow?
    private let appState = AppState()
    private var historyMenu: NSMenu!
    private var permissionItem: NSMenuItem!
    private var liveItem: NSMenuItem!
    private var modeMenu: NSMenu!
    private var pausedMedia = false
    /// Pedidos de permissão do Claude Code esperando resposta (o mais antigo primeiro).
    private var permissions: [AgentHook.PermissionAsk] = []
    /// O ditado em andamento é a resposta a este pedido (não cola nada).
    private var answering: AgentHook.PermissionAsk?
    private var selection: String?

    // Call
    private var callMic: Recorder?
    private var callSystem: SystemAudioRecorder?
    /// Quanto o áudio do sistema começou depois do mic: vira silêncio no início do system.wav para os dois ficarem alinhados.
    private var callSystemDelay: TimeInterval = 0
    private var callStart: Date?
    private var callTimer: Timer?
    private var processing = false
    private var suggestedFor: String?

    private var callItem: NSMenuItem!
    private var statusLine: NSMenuItem!

    private static let rightOption: UInt16 = 61
    private static let escape: UInt16 = 53
    private static let tapThreshold = 0.3

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = Logo.appIcon(size: 512)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        appState.startCall = { [weak self] in self?.toggleCall() }
        appState.transcribeFile = { [weak self] in self?.transcribeFile() }
        appState.importMeeting = { [weak self] in self?.importMeeting() }
        appState.redo = { [weak self] e, m in self?.redo(e, as: m) }
        appState.nameSpeakers = { [weak self] dir in self?.nameSpeakers(dir: dir) }
        appState.openAccessibility = { [weak self] in self?.openAccessibility() }
        // `open -a Hermes --env HERMES_OPEN=calls` abre direto numa seção.
        if let name = ProcessInfo.processInfo.environment["HERMES_OPEN"],
           let section = AppState.Section.allCases.first(where: { "\($0)" == name }) {
            DispatchQueue.main.async { self.openMain(section: section) }
        }
        // `HERMES_OPEN=live` mostra a janela da call (sem gravar), para conferir o visual.
        if ProcessInfo.processInfo.environment["HERMES_OPEN"] == "live" { DispatchQueue.main.async { self.showLiveCall() } }
        setState("ellipsis.circle", "Carregando modelos…")

        Log.write("início, acessibilidade=\(Paster.ensureAccessibility())")
        // Um app travado (navegador, VS Code) não pode segurar o Hermes: cada consulta de acessibilidade desiste em 0,5 s.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        MainWatchdog.start { [weak self] in self?.callStart != nil }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return e
        } as Any)

        callHotKey = HotKey(keyCode: kVK_ANSI_R, modifiers: optionKey | cmdKey) { [weak self] in
            MainActor.assumeIsolated { self?.toggleCall() }
        }
        detector = CallDetector { [weak self] app in self?.callDetected(app) }
        DistributedNotificationCenter.default().addObserver(forName: AgentHook.permissionRequest, object: nil, queue: .main) { [weak self] n in
            let payload = n.object as? String
            MainActor.assumeIsolated { self?.permissionAsked(payload) }
        }
        DistributedNotificationCenter.default().addObserver(forName: AgentHook.notification, object: nil, queue: .main) { [weak self] n in
            let payload = n.object as? String
            MainActor.assumeIsolated { self?.agentEvent(payload) }
        }

        Task {
            do {
                try await transcriber.load()
                await downloadModels()
                setState("waveform", "Pronto — ⌥ direito dita · ⌥⌘R grava call (aquecendo modelo PT…)")
                _ = await transcriber.warmUp()
                idleState()
            } catch {
                setState("exclamationmark.triangle", "Erro ao carregar modelo: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()
        statusLine = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        callItem = menu.addItem(withTitle: "Gravar call", action: #selector(toggleCall), keyEquivalent: "r")
        callItem.keyEquivalentModifierMask = [.command, .option]
        liveItem = menu.addItem(withTitle: "Ver transcrição e chat da call", action: #selector(showLiveCall), keyEquivalent: "l")
        liveItem.isHidden = true
        menu.addItem(withTitle: "Transcrever arquivo…", action: #selector(transcribeFile), keyEquivalent: "o")
        let modeItem = menu.addItem(withTitle: "Modo", action: nil, keyEquivalent: "")
        modeMenu = NSMenu()
        modeMenu.delegate = self
        modeItem.submenu = modeMenu
        let historyItem = menu.addItem(withTitle: "Copiar ditado recente", action: nil, keyEquivalent: "")
        historyMenu = NSMenu()
        historyMenu.delegate = self
        historyItem.submenu = historyMenu
        permissionItem = menu.addItem(withTitle: "⚠︎ Permitir colar automaticamente…", action: #selector(openAccessibility), keyEquivalent: "")
        permissionItem.isHidden = AXIsProcessTrusted()
        menu.addItem(.separator())
        // O resto (calls, vocabulário, ajustes) mora na janela: o menu fica só com ações de um clique.
        menu.addItem(withTitle: "Abrir Hermes…", action: #selector(openMainFromMenu), keyEquivalent: "0")
        menu.addItem(withTitle: "Sair do Hermes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Instalação nova: baixa o modelo de transcrição (2,2 GB) antes de aquecer e a IA local (2,5 GB) em segundo plano.
    /// Enquanto isso o ditado já funciona com o Parakeet.
    private func downloadModels() async {
        if !Models.missing(Models.cohere).isEmpty {
            do {
                try await Models.download(Models.cohere) { f in
                    Task { @MainActor [weak self] in
                        self?.setState("arrow.down.circle", "Pronto (baixando modelo de português: \(Int(f * 100))%)")
                    }
                }
                await transcriber.retryCohere()
            } catch {
                Log.write("download do Cohere: \(error.localizedDescription)")
            }
        }
        if Models.missingTools.contains("llama.cpp") == false, !Models.missing(Models.llm).isEmpty {
            Task.detached { try? await Models.download(Models.llm) { _ in } }
        }
    }

    private func setState(_ symbol: String, _ text: String) {
        // Parado ou gravando call: a asa do Hermes. Demais estados: símbolo do sistema.
        statusItem.button?.image = switch symbol {
        case "waveform": Logo.menuBarIcon()
        case "record.circle.fill": Logo.menuBarIcon(recording: true)
        default: NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        }
        appState.status = text.replacingOccurrences(of: " — ⌥ direito dita · ⌥⌘R grava call", with: "")
        appState.recordingCall = callStart != nil
        statusItem.button?.toolTip = text
        statusLine.title = text
    }

    private func idleState() {
        if callStart != nil { return }
        setState("waveform", "Pronto — ⌥ direito dita · ⌥⌘R grava call")
    }

    /// Claude Code terminou ou precisa de você: avisa na pílula; clicar volta para o terminal.
    private func agentEvent(_ payload: String?) {
        guard let data = payload?.data(using: .utf8), let e = try? JSONDecoder().decode(AgentHook.Event.self, from: data) else { return }
        // Não interrompe ditado, call ou processamento; e se o terminal já está na frente, você já está vendo.
        guard !dictating, callStart == nil, !processing else { return }
        if !e.bundle.isEmpty, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == e.bundle { return }
        let title: String
        switch e.kind {
        case "stop": title = "Claude terminou · \(e.project)" + (e.text.isEmpty ? "" : " — \(e.text)")
        case "permission": title = "Claude pede permissão · \(e.project)" + (e.text.isEmpty ? "" : " — \(e.text)")
        case "waiting": title = "Claude espera sua resposta · \(e.project)"
        default: title = "Claude · \(e.project) — \(e.text)"
        }
        NSSound(named: e.kind == "permission" ? "Glass" : "Purr")?.play()
        hud.show(autoHide: e.kind == "stop" ? 8 : 25) { m in
            m.kind = .suggestion
            m.symbol = e.kind == "permission" ? "hand.raised.fill" : "sparkle"
            m.tint = .orange
            m.title = title.count > 90 ? String(title.prefix(90)) + "…" : title
            m.detail = ""
            m.liveText = ""
            m.showControls = true
            m.actionSymbol = "arrow.up.forward.app"
            m.onStop = { [weak self] in
                self?.hud.hide()
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: e.bundle) {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }
            }
            m.onCancel = { [weak self] in self?.hud.hide() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // O llama-server é filho do Hermes; não deixa ele rodando sozinho.
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "llama-server.*--port 8737"]
        try? kill.run()
        kill.waitUntilExit()
    }

    // MARK: - Janela principal

    @objc private func openMainFromMenu() { openMain(section: nil) }

    private func openMain(section: AppState.Section?) {
        if let section { appState.section = section }
        if mainWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 620),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Hermes"
            w.contentView = NSHostingView(rootView: MainView(state: appState, history: history))
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("HermesMain")
            if !w.setFrameUsingName("HermesMain") { w.center() }
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                // Sem janela, volta a ser só barra de menus (sem ícone no Dock).
                NSApp.setActivationPolicy(.accessory)
            }
            mainWindow = w
        }
        appState.reloadCalls()
        appState.refreshPermissions()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// Abrir o app de novo (Finder, Spotlight, Dock) mostra a janela.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMain(section: nil)
        return false
    }

    // MARK: - Histórico

    @objc private func openHistory() {
        openMain(section: .dictations)
    }

    @objc private func pinMode(_ sender: NSMenuItem) {
        ModeStore.shared.pinned = sender.representedObject as? UUID
    }

    @objc private func editModes() { openMain(section: .modes) }

    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        History.copy(text)
    }

    @objc private func openAccessibility() {
        _ = Paster.ensureAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: - Teclado

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            if dictating && event.keyCode == Self.escape { cancelDictation(reason: "Esc"); return }
            // ⌥ direito usado como modificador (ex.: ⌥E para acento) não é ditado.
            if dictating && !handsFree { cancelDictation(silent: true, reason: "tecla \(event.keyCode) com ⌥") }
            return
        }
        guard event.keyCode == Self.rightOption else { return }
        let pressed = event.modifierFlags.contains(.option)
        if pressed {
            if handsFree { ignoreRelease = true; finishDictation(); return }
            if !dictating { pressedAt = event.timestamp; startDictation() }
        } else {
            if ignoreRelease { ignoreRelease = false; return }
            guard dictating, !handsFree else { return }
            // Tempo pelo relógio do evento: ligar o mic (AirPods) pode prender a thread por quase 1 s.
            if event.timestamp - pressedAt < Self.tapThreshold { enterHandsFree() } else { finishDictation() }
        }
    }

    // MARK: - Ditado

    /// Pílula e som primeiro, na hora do ⌥; o mic (que com AirPods leva quase 1 s para ligar) vem logo depois.
    private func startDictation() {
        let t0 = Date()
        answering = permissions.first
        mode = ModeStore.shared.forFrontApp()
        targetApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        selection = nil
        dictating = true
        handsFree = false
        pausedMedia = false
        NSSound(named: "Tink")?.play()
        setState("mic.fill", "Ditando (\(mode.rawValue))…")
        let answer = answering != nil
        hud.show(fade: false) { m in
            m.kind = .listening
            m.symbol = mode.symbol
            m.tint = .white
            m.title = answer ? "Resposta ao Claude: sim, não ou o que fazer" : mode.rawValue
            m.detail = ""
            m.showControls = false
            m.liveText = ""
            m.resetLevels()
        }
        CATransaction.flush()
        let token = UUID()
        dictationToken = token
        DispatchQueue.main.async { [weak self] in
            guard let self, self.dictating, self.dictationToken == token else { return }
            self.beginRecording(t0)
        }
    }

    private func beginRecording(_ t0: Date) {
        do {
            try recorder.start()
        } catch {
            dictating = false
            hud.hide()
            setState("exclamationmark.triangle", "Mic: \(error.localizedDescription)")
            return
        }
        selection = DictationContext.selectedText()
        // A IA local sobe enquanto você fala (fica pronta para o fim do ditado).
        if mode.systemPrompt != nil || selection != nil, Config.load().polishEngine == "local", LocalLLM.isAvailable {
            Task { try? await LocalLLM.shared.start() }
        }
        pausedMedia = Config.load().pauseMedia && Media.pauseIfPlaying()
        startMeter(recorder)
        Log.write(String(format: "ditado: início (%@, %@), preparo %.1f s", mode.name, targetApp, Date().timeIntervalSince(t0)))
        let language = Config.load().language
        let recorder = recorder, transcriber = transcriber
        liveTask = Task { [weak self] in
            var seg = LiveSegmenter()
            while !Task.isCancelled, self?.dictating == true {
                await seg.step(recorder.samples(from: seg.openStart), transcriber: transcriber, language: language)
                guard !Task.isCancelled, let self, self.dictating else { break }
                if self.hud.model.liveText != seg.text {
                    self.hud.model.liveText = seg.text
                    self.hud.layout()
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            return seg
        }
    }

    private func enterHandsFree() {
        handsFree = true
        hud.show { m in
            m.title = "\(mode.rawValue) · mãos livres"
            m.showControls = true
            m.onStop = { [weak self] in self?.finishDictation() }
            m.onCancel = { [weak self] in self?.cancelDictation(reason: "botão ✗") }
        }
    }

    private func cancelDictation(silent: Bool = false, reason: String) {
        Log.write("ditado: cancelado (\(reason))")
        dictating = false
        dictationToken = UUID()
        handsFree = false
        _ = recorder.stop()
        resumeMedia()
        liveTask?.cancel()
        liveTask = nil
        hud.model.liveText = ""
        stopMeter()
        if !silent { NSSound(named: "Funk")?.play() }
        answering = nil
        restoreHUD()
        idleState()
    }

    private func finishDictation() {
        dictating = false
        dictationToken = UUID()
        handsFree = false
        let samples = recorder.stop()
        stopMeter()
        NSSound(named: "Pop")?.play()
        resumeMedia()
        guard samples.count > Int(Audio.sampleRate * 0.4) else {
            Log.write(String(format: "ditado: descartado, só %.1f s de áudio", Double(samples.count) / Audio.sampleRate))
            restoreHUD(); idleState(); return
        }
        setState("hourglass", "Transcrevendo…")
        hud.show { m in
            m.kind = .processing
            m.title = "Transcrevendo"
            m.showControls = false
        }
        let cfg = Config.load()
        let mode = mode
        let live = liveTask
        liveTask = nil
        Task {
            // Fecha só o trecho que ainda estava aberto; o resto já foi transcrito enquanto você falava.
            var seg = await live?.value ?? LiveSegmenter()
            let t0 = Date()
            await seg.step(Array(samples[min(seg.openStart, samples.count)...]), transcriber: transcriber,
                           language: cfg.language, final: true)
            var text = seg.text
            Log.write(String(format: "ditado: %d s de áudio, %d palavras, fim da transcrição em %.1f s",
                             samples.count / Int(Audio.sampleRate), text.split(separator: " ").count, Date().timeIntervalSince(t0)))
            if let ask = answering {
                answering = nil
                hud.model.liveText = ""
                let (allow, message) = AgentHook.interpret(text)
                if text.isEmpty { restoreHUD() } else { answerPermission(ask, allow: allow, message: message) }
                idleState()
                return
            }
            hud.model.liveText = text
            let kind = Polisher.kind(text, mode: mode, selection: selection)
            if kind != .none {
                hud.show { $0.title = Polisher.label(kind, mode: mode) }
                // A IA não pode prender o ditado: passou de 30 s, cola o texto como saiu da transcrição.
                let raw = text, app = targetApp, sel = selection
                let polished = await withTimeout(30) { await Polisher.run(raw, mode: mode, app: app, selection: sel, config: cfg) }
                if polished == nil { Log.write("ditado: IA passou de 30 s, colando sem polimento") }
                text = polished ?? raw
            }
            hud.model.liveText = ""
            guard !text.isEmpty else { restoreHUD(); idleState(); return }
            history.add(text, mode: mode.name, app: targetApp, samples: samples, raw: seg.text)
            if Paster.paste(text) {
                restoreHUD()
            } else {
                permissionItem.isHidden = false
                hud.show(autoHide: 4) { m in
                    m.kind = .suggestion
                    m.symbol = "doc.on.clipboard.fill"
                    m.tint = .yellow
                    m.title = "Copiado — cole com ⌘V (falta permissão de Acessibilidade)"
                    m.showControls = false
                }
            }
            idleState()
        }
    }

    /// Refaz um ditado a partir do áudio salvo: transcreve de novo e aplica o modo escolhido. Resultado vai para o clipboard.
    private func redo(_ entry: DictationEntry, as newMode: DictationMode?) {
        guard let url = entry.audioURL, !processing else { return }
        let mode = newMode ?? ModeStore.shared.modes.first { $0.name == entry.mode } ?? ModeStore.shared.fallback
        let cfg = Config.load()
        let transcriber = transcriber
        processing = true
        showProcessing("Refazendo como \(mode.name)")
        Task {
            defer { processing = false }
            do {
                let samples = try await Task.detached { try History.readAudio(url) }.value
                let segments = await LiveSegmenter.transcribeAll(samples, transcriber: transcriber, language: cfg.language) { _ in }
                var text = segments.map(\.text).joined(separator: " ")
                if newMode != nil || mode.systemPrompt != nil {
                    text = await Polisher.run(text, mode: mode, app: entry.app, selection: nil, config: cfg)
                }
                guard !text.isEmpty else { hud.hide(); notify("Nenhuma fala no áudio"); return }
                history.update(entry.id, text: text, mode: mode.name)
                History.copy(text)
                hud.show(autoHide: 3) { m in
                    m.kind = .suggestion
                    m.symbol = "doc.on.clipboard.fill"
                    m.tint = .white
                    m.title = "Refeito como \(mode.name) e copiado"
                    m.showControls = false
                }
            } catch {
                hud.hide()
                notify("Refazer: \(error.localizedDescription)")
            }
        }
    }

    private func resumeMedia() {
        guard pausedMedia else { return }
        pausedMedia = false
        Media.resume()
    }

    // MARK: - Arquivos

    private func pickMedia(_ title: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent]
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Áudio do WhatsApp, gravação, vídeo… → texto no clipboard e no histórico.
    @objc func transcribeFile() {
        let urls = pickMedia("Transcrever arquivos")
        guard !urls.isEmpty, !processing else { return }
        processing = true
        let cfg = Config.load()
        let transcriber = transcriber
        Task {
            defer { processing = false }
            var texts: [String] = []
            for (i, url) in urls.enumerated() {
                let name = url.lastPathComponent
                showProcessing("Lendo \(name)")
                do {
                    let samples = try await Task.detached { try Audio.readAny(url) }.value
                    let segments = await LiveSegmenter.transcribeAll(samples, transcriber: transcriber, language: cfg.language) { [weak self] f in
                        let label = "Transcrevendo \(urls.count > 1 ? "\(i + 1)/\(urls.count) " : "")\(Int(f * 100))%"
                        Task { @MainActor in self?.showProcessing(label) }
                    }
                    let text = segments.map(\.text).joined(separator: " ")
                    if !text.isEmpty {
                        history.add(text, mode: "Arquivo", app: name)
                        texts.append(urls.count > 1 ? "\(name):\n\(text)" : text)
                    }
                } catch {
                    notify("\(name): \(error.localizedDescription)")
                }
            }
            hud.hide()
            guard !texts.isEmpty else { notify("Nenhuma fala encontrada"); return }
            History.copy(texts.joined(separator: "\n\n"))
            notify("Transcrição copiada (também no histórico)")
            openHistory()
        }
    }

    /// Gravação de reunião feita fora do Hermes → mesma pipeline da call: falantes, resumo e nota.
    @objc func importMeeting() {
        guard let url = pickMedia("Importar gravação de reunião").first, !processing, callStart == nil else { return }
        processing = true
        let cfg = Config.load()
        let transcriber = transcriber
        let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let dir = Config.callsDir.appendingPathComponent(df.string(from: date), isDirectory: true)
        Task {
            defer { processing = false }
            do {
                showProcessing("Lendo \(url.lastPathComponent)")
                try await Task.detached {
                    let samples = try Audio.readAny(url)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    // Tudo vai como "áudio do sistema": sem canal separado do seu mic, todos passam pela separação de falantes.
                    try Audio.writeWAV(samples, to: dir.appendingPathComponent("system.wav"))
                }.value
                let t = try await CallFlow.finish(dir: dir, date: date, transcriber: transcriber, config: cfg) { [weak self] msg in
                    Task { @MainActor in self?.showProcessing(msg.replacingOccurrences(of: "…", with: "")) }
                }
                hud.hide()
                notify("Reunião salva: \(t.title ?? t.id)")
                if t.speakers.contains(where: { !$0.known && $0.embedding != nil }) { nameSpeakers(dir: dir) }
                processing = false
                await refineCall(dir: dir, config: cfg)
            } catch {
                hud.hide()
                notify("Importar: \(error.localizedDescription)")
            }
        }
    }

    /// Depois do ditado: volta para a pílula da call se houver uma gravando; senão esconde.
    private func restoreHUD() {
        if let mic = callMic { showCallHUD(); startMeter(mic) } else if !permissions.isEmpty { showPermission() } else { hud.hide() }
    }

    // MARK: - Permissões do Claude Code

    private func permissionAsked(_ payload: String?) {
        guard let data = payload?.data(using: .utf8), let ask = try? JSONDecoder().decode(AgentHook.PermissionAsk.self, from: data) else { return }
        // Terminal na frente: você já está vendo o pedido lá; o Claude Code pergunta como sempre.
        if !ask.bundle.isEmpty, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ask.bundle {
            AgentHook.reply(.init(id: ask.id, action: "pass"))
            return
        }
        AgentHook.reply(.init(id: ask.id, action: "ack"))
        permissions.append(ask)
        NSSound(named: "Glass")?.play()
        // O hook desiste em 2 min; aí o pedido volta para o terminal.
        DispatchQueue.main.asyncAfter(deadline: .now() + 118) { [weak self] in self?.dropPermission(ask.id, notify: true) }
        if !dictating, !processing, permissions.count == 1 { showPermission() }
    }

    private func showPermission() {
        guard let ask = permissions.first, !dictating else { return }
        let more = permissions.count > 1 ? " (+\(permissions.count - 1))" : ""
        hud.show { m in
            m.kind = .suggestion
            m.symbol = "hand.raised.fill"
            m.tint = .orange
            m.title = "Claude quer usar \(ask.tool) · \(ask.project)\(more) — segure ⌥ e diga sim ou não"
            m.detail = ""
            m.liveText = ask.summary
            m.showControls = true
            m.actionSymbol = "checkmark"
            m.onStop = { [weak self] in self?.answerPermission(ask, allow: true, message: nil) }
            m.onCancel = { [weak self] in self?.answerPermission(ask, allow: false, message: nil) }
        }
    }

    private func answerPermission(_ ask: AgentHook.PermissionAsk, allow: Bool, message: String?) {
        guard permissions.contains(where: { $0.id == ask.id }) else { return }
        AgentHook.reply(.init(id: ask.id, action: allow ? "allow" : "deny", message: message))
        permissions.removeAll { $0.id == ask.id }
        NSSound(named: allow ? "Pop" : "Funk")?.play()
        hud.show(autoHide: 1.5) { m in
            m.kind = .suggestion
            m.symbol = allow ? "checkmark.circle.fill" : "xmark.circle.fill"
            m.tint = allow ? .green : .orange
            m.title = allow ? "Permitido: \(ask.tool)" : (message.map { "Negado, com instrução: \($0)" } ?? "Negado: \(ask.tool)")
            m.liveText = ""
            m.showControls = false
        }
        if !permissions.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.showPermission() }
        }
    }

    private func dropPermission(_ id: String, notify: Bool) {
        guard permissions.contains(where: { $0.id == id }) else { return }
        permissions.removeAll { $0.id == id }
        if answering?.id == id { answering = nil }
        if !dictating { restoreHUD() }
    }

    private func startMeter(_ source: Recorder) {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            // Fala fica em ~-45…-15 dBFS; escala logarítmica deixa as barras vivas.
            let db = 20 * log10(max(source.level, 1e-5))
            MainActor.assumeIsolated { self?.hud.model.push(level: CGFloat((db + 50) / 38)) }
        }
    }

    private func stopMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    // MARK: - Calls

    /// Um app de reunião começou a usar o mic: sugere gravar (sem gravar sozinho).
    private func callDetected(_ app: String?) {
        guard let app else {
            if callStart != nil, let since = callStart, Date().timeIntervalSince(since) > 30 {
                hud.show { m in m.title = "A call terminou? · Parar e salvar" }
            }
            suggestedFor = nil
            if callStart == nil && !dictating && !processing && hud.model.kind == .suggestion { hud.hide() }
            return
        }
        guard callStart == nil, !dictating, !processing, suggestedFor != app else { return }
        suggestedFor = app
        hud.show(autoHide: 20) { m in
            m.kind = .suggestion
            m.symbol = "phone.fill"
            m.tint = .green
            m.title = "Call no \(app) — gravar? ⌥⌘R"
            m.detail = ""
            m.showControls = true
            m.onStop = { [weak self] in self?.startCall() }
            m.onCancel = { [weak self] in self?.hud.hide() }
        }
    }

    @objc private func toggleCall() {
        callStart == nil ? startCall() : stopCall()
    }

    private func startCall() {
        guard !processing else { notify("Ainda processando a call anterior"); return }
        let t0 = Date()
        let mic = Recorder()
        do {
            try mic.start()
        } catch {
            notify("Não consegui abrir o microfone: \(error.localizedDescription)"); return
        }
        let start = Date()
        Log.write(String(format: "call: mic ligado em %.1f s", start.timeIntervalSince(t0)))
        // O áudio do sistema (tap + dispositivo agregado) pode levar segundos com fone Bluetooth: liga fora da thread principal.
        callSystem = nil
        callSystemDelay = 0
        Task { [weak self] in
            let sys = SystemAudioRecorder()
            do {
                try await Task.detached { try sys.start() }.value
                guard let self, self.callStart == start else { _ = sys.stop(); return }
                self.callSystemDelay = Date().timeIntervalSince(start)
                self.callSystem = sys
                Log.write(String(format: "call: áudio do sistema ligado em %.1f s", self.callSystemDelay))
            } catch {
                self?.notify("Gravando só o microfone — áudio do sistema indisponível: \(error.localizedDescription)")
            }
        }
        callMic = mic
        callStart = start
        callItem.title = "Parar e processar call"
        liveItem.isHidden = false
        NSSound(named: "Tink")?.play()
        callTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickCall() }
        }
        showCallHUD()
        startMeter(mic)
        startLiveCall()
    }

    // MARK: - Call ao vivo

    private func startLiveCall() {
        let cfg = Config.load()
        liveCall.myName = cfg.myName
        liveCall.lines = []
        liveCall.partials = [:]
        liveCall.messages = []
        liveCall.running = true
        liveCall.startedAt = Date()
        showLiveCall()
        let transcriber = transcriber
        liveCallTask = Task { [weak self] in
            var mic = LiveSegmenter(), sys = LiveSegmenter()
            var turn = 0
            while !Task.isCancelled, let self, self.callStart != nil {
                // Sistema antes do mic: o filtro de eco compara a fala do mic com as do sistema já vistas.
                if let rec = self.callSystem {
                    let closed = await sys.step(rec.samples(from: sys.openStart), transcriber: transcriber,
                                                language: cfg.language, preview: turn % 2 == 0)
                    for s in closed { self.liveCall.add(s, speaker: "Outros") }
                    self.liveCall.partials["Outros"] = sys.partial
                }
                if let rec = self.callMic {
                    let closed = await mic.step(rec.samples(from: mic.openStart), transcriber: transcriber,
                                                language: cfg.language, preview: turn % 2 == 1)
                    for s in closed { self.liveCall.add(s, speaker: cfg.myName) }
                    self.liveCall.partials[cfg.myName] = mic.partial
                }
                turn += 1
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    @objc private func showLiveCall() {
        if liveWindow == nil {
            // Vidro escuro translúcido no visual da pílula: dá para ver o que está atrás; arrasta pelo fundo e redimensiona pelas bordas.
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
                                styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.title = "Hermes — Call ao vivo"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(b)?.isHidden = true }
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.isMovableByWindowBackground = true
            panel.minSize = NSSize(width: 320, height: 280)
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let host = NSHostingView(rootView: LiveCallView(call: liveCall, config: { Config.load() }, close: { [weak panel] in panel?.orderOut(nil) }))
            panel.contentView = Glass.wrap(host, cornerRadius: 22)
            panel.setFrameAutosaveName("HermesLiveCall")
            if !panel.setFrameUsingName("HermesLiveCall"), let screen = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: screen.maxX - 480, y: screen.maxY - 640))
            }
            liveWindow = panel
        }
        liveWindow?.orderFrontRegardless()
    }

    private func showCallHUD() {
        hud.show { m in
            m.kind = .listening
            m.symbol = "record.circle.fill"
            m.tint = .red
            m.title = "Call"
            m.showControls = true
            m.onStop = { [weak self] in self?.stopCall() }
            m.onCancel = nil
            m.resetLevels()
        }
        tickCall()
    }

    private func tickCall() {
        guard let start = callStart else { return }
        let s = Int(Date().timeIntervalSince(start))
        let time = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
        setState("record.circle.fill", "Gravando call — \(time)")
        statusItem.button?.title = " \(time)"
        if !dictating, hud.model.symbol == "record.circle.fill" {
            hud.model.detail = time
            hud.layout()
        }
    }

    private func stopCall() {
        guard let start = callStart else { return }
        callTimer?.invalidate()
        let mic = callMic, sys = callSystem
        let sysPad = [Float](repeating: 0, count: Int(callSystemDelay * Audio.sampleRate))
        callMic = nil
        callSystem = nil
        callStart = nil
        callItem.title = "Gravar call"
        liveItem.isHidden = true
        statusItem.button?.title = ""
        liveCallTask?.cancel()
        liveCallTask = nil
        liveCall.running = false
        liveCall.partials = [:]
        stopMeter()
        NSSound(named: "Pop")?.play()

        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let dir = Config.callsDir.appendingPathComponent(df.string(from: start), isDirectory: true)
        processing = true
        setState("hourglass", "Processando call…")
        // Processa em segundo plano: nada no meio da tela, só a ampulheta na barra de menus e a notificação no fim.
        if !dictating { hud.hide() }
        let cfg = Config.load()
        let transcriber = transcriber
        Task {
            defer { processing = false }
            do {
                try await Task.detached {
                    let micSamples = mic?.stop() ?? []
                    let sysSamples = sys.map { sysPad + $0.stop() } ?? []
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    if !micSamples.isEmpty { try Audio.writeWAV(micSamples, to: dir.appendingPathComponent("mic.wav")) }
                    if !sysSamples.isEmpty { try Audio.writeWAV(sysSamples, to: dir.appendingPathComponent("system.wav")) }
                }.value
                let t = try await CallFlow.finish(dir: dir, date: start, transcriber: transcriber, config: cfg) { [weak self] msg in
                    Task { @MainActor in self?.setState("hourglass", msg) }
                    NSLog("Hermes: %@", msg)
                }
                idleState()
                let unknown = t.speakers.filter { !$0.known && $0.embedding != nil }.count
                notify("Call salva: \(t.title ?? t.id)" + (unknown > 0 ? " — \(unknown) falante(s) para nomear" : ""))
                if unknown > 0 { nameLatestSpeakers() }
                processing = false
                await refineCall(dir: dir, config: cfg)
            } catch {
                setState("exclamationmark.triangle", "Erro na call: \(error.localizedDescription)")
                notify("Call: \(error.localizedDescription)")
            }
        }
    }

    /// Texto final com o Cohere, quieto, depois da nota pronta: pausa enquanto você dita ou grava outra call.
    /// Já não conta como "processando": dá para começar outra call ou importar no meio.
    private func refineCall(dir: URL, config: Config) async {
        let t0 = Date()
        do {
            try await CallFlow.refine(dir: dir, transcriber: transcriber, config: config, log: { NSLog("Hermes: %@", $0) }) { [weak self] in
                await MainActor.run { self.map { $0.dictating || $0.callStart != nil } ?? false }
            }
            Log.write(String(format: "call: texto refinado em %.0f s", Date().timeIntervalSince(t0)))
        } catch {
            Log.write("call: refino falhou: \(error.localizedDescription)")
        }
    }

    private func showProcessing(_ text: String) {
        guard !dictating, callStart == nil else { return }
        hud.show { m in
            m.kind = .processing
            m.symbol = "doc.text.fill"
            m.tint = .orange
            m.title = text
            m.detail = ""
            m.showControls = false
        }
    }

    @objc private func nameLatestSpeakers() {
        guard let dir = CallFlow.latestCallDir() else { notify("Nenhuma call processada ainda"); return }
        nameSpeakers(dir: dir)
    }

    private func nameSpeakers(dir: URL) {
        guard let t = try? CallPipeline.load(dir: dir) else {
            notify("Nenhuma call processada ainda"); return
        }
        let candidates = t.speakers.filter { $0.id != CallPipeline.meID && $0.embedding != nil }
        guard !candidates.isEmpty else { notify("Essa call não tem outros falantes"); return }

        let alert = NSAlert()
        alert.messageText = "Quem é quem? — \(t.title ?? t.id)"
        alert.informativeText = "Veja na nota o que cada um falou. Nomes salvos viram perfis de voz e são reconhecidos nas próximas calls. Deixe em branco para manter."
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        var fields: [(String, NSTextField)] = []
        for s in candidates {
            let first = t.turns.first { $0.speaker == s.id }?.text.prefix(70) ?? ""
            let hint = t.suggestions?[s.label]
            let label = NSTextField(wrappingLabelWithString: "\(s.label): “\(first)…”" + (hint.map { "\nSugestão: \($0.name) — \($0.reason)" } ?? ""))
            label.preferredMaxLayoutWidth = 320
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            field.placeholderString = s.known ? s.label : "Nome"
            field.stringValue = s.known ? s.label : (hint?.name ?? "")
            field.widthAnchor.constraint(equalToConstant: 320).isActive = true
            stack.addArrangedSubview(label)
            stack.addArrangedSubview(field)
            fields.append((s.label, field))
        }
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: CGFloat(candidates.count) * 76)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Salvar")
        alert.addButton(withTitle: "Cancelar")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var names: [String: String] = [:]
        for (old, field) in fields { names[old] = field.stringValue }
        // git push ou Notion vão pela rede: fora da thread principal.
        let config = Config.load()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try CallFlow.rename(dir: dir, names: names, config: config) { NSLog("Hermes: %@", $0) } }
            DispatchQueue.main.async { [weak self] in
                switch result {
                case .success: self?.notify("Falantes salvos")
                case .failure(let error): self?.notify("Erro ao nomear: \(error.localizedDescription)")
                }
            }
        }
    }

    private func notify(_ text: String) {
        statusLine.title = text
        NSLog("Hermes: %@", text)
        let n = NSUserNotificationCenterShim.self
        n.show(text)
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Submenu com os 10 últimos ditados; clicar copia.
    func menuNeedsUpdate(_ menu: NSMenu) {
        permissionItem.isHidden = AXIsProcessTrusted()
        if menu === modeMenu {
            menu.removeAllItems()
            let store = ModeStore.shared
            let auto = menu.addItem(withTitle: "Automático (pelo app ou site)", action: #selector(pinMode(_:)), keyEquivalent: "")
            auto.target = self
            auto.state = store.pinned == nil ? .on : .off
            menu.addItem(.separator())
            for m in store.modes {
                let item = menu.addItem(withTitle: m.name, action: #selector(pinMode(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = m.id
                item.image = NSImage(systemSymbolName: m.symbol, accessibilityDescription: nil)
                item.state = store.pinned == m.id ? .on : .off
            }
            menu.addItem(.separator())
            let edit = menu.addItem(withTitle: "Editar modos…", action: #selector(editModes), keyEquivalent: "")
            edit.target = self
            return
        }
        guard menu === historyMenu else { return }
        menu.removeAllItems()
        let recent = history.entries.prefix(10)
        if recent.isEmpty { menu.addItem(withTitle: "Nenhum ditado ainda", action: nil, keyEquivalent: "") }
        for e in recent {
            let title = e.text.count > 60 ? String(e.text.prefix(60)) + "…" : e.text
            let item = menu.addItem(withTitle: title, action: #selector(copyHistoryEntry(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = e.text
            item.toolTip = "Clique para copiar"
        }
    }
}

/// Aviso leve sem depender de permissão de notificações: um balão no ícone.
enum NSUserNotificationCenterShim {
    @MainActor static func show(_ text: String) {
        let script = "display notification \(String(reflecting: text)) with title \"Hermes\""
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }
}

// MARK: - Entrada

if CommandLine.arguments.dropFirst().first == "agent-hook" {
    AgentHook.run()
    exit(0)
}

if CommandLine.arguments.dropFirst().first == "permission-hook" {
    AgentHook.runPermission()
    exit(0)
}

if CommandLine.arguments.count > 1 {
    exit(CLI.run(Array(CommandLine.arguments.dropFirst())))
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
