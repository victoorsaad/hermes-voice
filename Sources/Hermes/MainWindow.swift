import AppKit
import ServiceManagement
import SwiftUI

/// O que a janela mostra e pede ao app. O AppDelegate preenche o estado e executa as ações.
@MainActor
final class AppState: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case home = "Início", calls = "Calls", dictations = "Ditados", modes = "Modos", vocabulary = "Vocabulário", settings = "Ajustes"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .home: "house"
            case .calls: "phone"
            case .dictations: "text.bubble"
            case .modes: "slider.horizontal.3"
            case .vocabulary: "character.book.closed"
            case .settings: "gearshape"
            }
        }
    }

    @Published var section: Section = .home
    @Published var status = "Carregando modelos…"
    @Published var recordingCall = false
    @Published var accessibility = AXIsProcessTrusted()
    @Published var calls: [CallSummary] = []
    @Published var selectedCall: String?
    @Published var pendingDelete: CallSummary?

    var startCall: () -> Void = {}
    var transcribeFile: () -> Void = {}
    var importMeeting: () -> Void = {}
    var nameSpeakers: (URL) -> Void = { _ in }
    var openAccessibility: () -> Void = {}
    var redo: (DictationEntry, DictationMode?) -> Void = { _, _ in }

    struct CallSummary: Identifiable {
        let id: String
        let dir: URL
        let transcript: CallTranscript
    }

    func reloadCalls() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Config.callsDir, includingPropertiesForKeys: nil)) ?? []
        calls = dirs.compactMap { dir in
            (try? CallPipeline.load(dir: dir)).map { CallSummary(id: dir.lastPathComponent, dir: dir, transcript: $0) }
        }.sorted { $0.transcript.date > $1.transcript.date }
        if selectedCall == nil { selectedCall = calls.first?.id }
    }

    func refreshPermissions() { accessibility = AXIsProcessTrusted() }

    /// Exclui a call em todo lugar: nota (Markdown + commit/push, ou Notion) e gravação. Os dois vão para o Lixo.
    func deleteCall(_ call: CallSummary) {
        let config = Config.load()
        if let rel = call.transcript.notePath {
            let id = call.id
            // git/push pode demorar (rede): fora da thread principal.
            DispatchQueue.global(qos: .utility).async {
                Vault(config: config, log: { Log.write($0) }).removeNote(rel, message: "Hermes: call excluída (\(id))")
            }
        }
        try? FileManager.default.trashItem(at: call.dir, resultingItemURL: nil)
        if selectedCall == call.id { selectedCall = nil }
        reloadCalls()
    }
}

struct MainView: View {
    @ObservedObject var state: AppState
    @ObservedObject var history: History

    var body: some View {
        NavigationSplitView {
            List(AppState.Section.allCases, selection: Binding(get: { state.section }, set: { if let s = $0 { state.section = s } })) { s in
                Label(s.rawValue, systemImage: s.symbol).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch state.section {
            case .home: HomeView(state: state, history: history)
            case .calls: CallsView(state: state)
            case .dictations: HistoryView(history: history, onRedo: state.redo)
            case .modes: ModesView()
            case .vocabulary: VocabularyView()
            case .settings: SettingsView()
            }
        }
        .tint(Color(nsColor: Logo.bronze.dark))
        .environment(\.locale, Locale(identifier: "pt_BR"))
        .frame(minWidth: 820, minHeight: 540)
    }
}

// MARK: - Início

private struct HomeView: View {
    @ObservedObject var state: AppState
    @ObservedObject var history: History

    private var today: [DictationEntry] { history.entries.filter { Calendar.current.isDateInToday($0.date) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .center, spacing: 18) {
                    Image(nsImage: Logo.appIcon(size: 168)).resizable().frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hermes").font(.system(size: 34, weight: .semibold, design: .serif))
                        Text(state.status).font(.title3).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Atalhos").font(.headline)
                    Shortcut(keys: ["⌥ direito"], text: "Segure e fale; solte para colar onde está o cursor")
                    Shortcut(keys: ["⌥ direito", "toque"], text: "Mãos livres: toque de novo para colar, Esc cancela")
                    Shortcut(keys: ["⌥", "⌘", "R"], text: "Gravar call (seu mic e o áudio do Mac) e virar nota (Markdown/Obsidian ou Notion)")
                    Shortcut(keys: ["⌘", "L"], text: "Transcrição e chat da call em andamento (com o menu aberto)")
                }

                if !state.accessibility {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Sem permissão de Acessibilidade, o Hermes copia o ditado mas não consegue colar sozinho.")
                        Spacer()
                        Button("Permitir") { state.openAccessibility() }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
                }

                if !Models.missingTools.isEmpty {
                    let cmd = "brew install " + Models.missingTools.joined(separator: " ")
                    HStack(spacing: 12) {
                        Image(systemName: "shippingbox").foregroundStyle(.secondary)
                        Text("Para a IA local e arquivos de vídeo/áudio de qualquer formato, instale no Terminal: \(cmd)")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Copiar comando") { History.copy(cmd) }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.12)))
                }

                HStack(spacing: 12) {
                    Button { state.startCall() } label: {
                        Label(state.recordingCall ? "Gravando call…" : "Gravar call", systemImage: "record.circle")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(state.recordingCall)
                    Button { state.transcribeFile() } label: { Label("Transcrever arquivo", systemImage: "doc.badge.arrow.up") }
                        .controlSize(.large)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Hoje").font(.headline)
                    Text(today.isEmpty
                         ? "Nenhum ditado ainda hoje."
                         : "\(today.count) ditado\(today.count == 1 ? "" : "s"), \(today.reduce(0) { $0 + $1.text.split(separator: " ").count }) palavras.")
                        .foregroundStyle(.secondary)
                    if let last = state.calls.first {
                        Text("Última call: \(last.transcript.title ?? "sem título"), \(last.transcript.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "pt_BR")))).")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .onAppear { state.refreshPermissions(); state.reloadCalls() }
    }
}

private struct Shortcut: View {
    let keys: [String]
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { k in
                    Text(k)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)))
                }
            }
            .frame(width: 150, alignment: .leading)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Calls

private struct CallsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        HSplitView {
            List(state.calls, selection: $state.selectedCall) { c in
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.transcript.title ?? "Call sem título").lineLimit(2)
                    Text("\(c.transcript.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "pt_BR")))), \(max(1, Int(c.transcript.duration / 60))) min")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
                .tag(c.id)
                .contextMenu { Button("Excluir call…", role: .destructive) { state.pendingDelete = c } }
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
            .safeAreaInset(edge: .bottom) {
                Button { state.importMeeting() } label: { Label("Importar gravação de reunião", systemImage: "square.and.arrow.down") }
                    .buttonStyle(.borderless)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
            .overlay {
                if state.calls.isEmpty {
                    Text("Nenhuma call gravada. Use ⌥⌘R ou o botão Gravar call no Início.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).padding()
                }
            }

            if let call = state.calls.first(where: { $0.id == state.selectedCall }) {
                CallDetail(call: call, state: state)
            } else {
                Text("Escolha uma call").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { state.reloadCalls() }
        .onDeleteCommand { state.pendingDelete = state.calls.first { $0.id == state.selectedCall } }
        .confirmationDialog("Excluir \"\(state.pendingDelete?.transcript.title ?? "call")\"?", isPresented: Binding(get: { state.pendingDelete != nil }, set: { if !$0 { state.pendingDelete = nil } })) {
            Button("Excluir", role: .destructive) {
                if let c = state.pendingDelete { state.deleteCall(c) }
                state.pendingDelete = nil
            }
        } message: {
            Text("A nota sai do destino (pasta/git ou Notion) e a gravação vai para o Lixo do Mac.")
        }
    }
}

private struct CallDetail: View {
    let call: AppState.CallSummary
    @ObservedObject var state: AppState

    private var t: CallTranscript { call.transcript }

    var body: some View {
        // A largura do texto segue a da coluna (antes o conteúdo crescia além dela e cortava título e botões).
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(t.title ?? "Call sem título")
                            .font(.system(size: 24, weight: .semibold, design: .serif))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(t.date.formatted(Date.FormatStyle(date: .complete, time: .shortened).locale(Locale(identifier: "pt_BR")))), \(max(1, Int(t.duration / 60))) min")
                            .foregroundStyle(.secondary)
                        Text(t.speakers.map(\.label).joined(separator: ", ")).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        if let rel = t.notePath {
                            Button(rel.hasPrefix(Notion.prefix) ? "Abrir no Notion" : "Abrir nota") {
                                if let url = Vault.url(for: rel, config: Config.load()) { NSWorkspace.shared.open(url) }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        if t.speakers.contains(where: { !$0.known && $0.embedding != nil }) {
                            Button("Nomear falantes…") { state.nameSpeakers(call.dir) }
                        }
                        Menu {
                            Button("Mostrar gravação no Finder") { NSWorkspace.shared.activateFileViewerSelecting([call.dir]) }
                            Divider()
                            Button("Excluir call…", role: .destructive) { state.pendingDelete = call }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Mais ações")
                    }
                    if let summary = t.summary {
                        MarkdownBlock(markdown: summary)
                    }
                    Divider()
                    Text("Transcrição").font(.headline)
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(t.turns.enumerated()), id: \.offset) { _, turn in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(t.label(turn.speaker))  \(CallPipeline.timestamp(turn.start))")
                                    .font(.caption.bold())
                                    .foregroundStyle(turn.speaker == CallPipeline.meID ? Color(nsColor: Logo.bronze.dark) : .secondary)
                                Text(turn.text)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(28)
                .frame(width: min(geo.size.width, 760), alignment: .leading)
            }
        }
        .frame(minWidth: 380, maxWidth: .infinity)
    }
}

/// Markdown do resumo: "## Título" vira cabeçalho, "- [ ]" vira caixinha, o resto é inline.
private struct MarkdownBlock: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("## ") {
                    Text(line.dropFirst(3)).font(.headline).padding(.top, 8)
                } else if line.hasPrefix("- [ ] ") {
                    Label { inline(String(line.dropFirst(6))) } icon: { Image(systemName: "square") }
                } else if line.hasPrefix("- ") {
                    Label { inline(String(line.dropFirst(2))) } icon: { Text("•") }
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    inline(line)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }

    private func inline(_ s: String) -> Text {
        Text((try? AttributedString(markdown: s)) ?? AttributedString(s))
    }
}

// MARK: - Vocabulário

private struct VocabularyView: View {
    private struct Swap: Identifiable { let id = UUID(); var from: String; var to: String }

    @State private var terms: [String] = []
    @State private var swaps: [Swap] = []
    @State private var newTerm = ""
    @State private var newFrom = ""
    @State private var newTo = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Novo termo (ex.: Supabase)", text: $newTerm).onSubmit(addTerm)
                    Button("Adicionar", action: addTerm).disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(terms, id: \.self) { term in
                    HStack {
                        Text(term)
                        Spacer()
                        Button { terms.removeAll { $0 == term }; save() } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remover")
                    }
                }
            } header: {
                Text("Nomes e termos")
            } footer: {
                Text("Quando a transcrição escrever algo parecido (\"Pro Meli\"), vira a grafia daqui. Nomes salvos dos falantes entram sozinhos.")
            }
            Section {
                HStack {
                    TextField("Ouvido como", text: $newFrom)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Escrever", text: $newTo).onSubmit(addSwap)
                    Button("Adicionar", action: addSwap).disabled(newFrom.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(swaps) { swap in
                    HStack {
                        Text(swap.from)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(swap.to)
                        Spacer()
                        Button { swaps.removeAll { $0.id == swap.id }; save() } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remover")
                    }
                }
            } header: {
                Text("Trocas fixas")
            } footer: {
                Text("Para palavras curtas ou que a transcrição erra sempre igual: \"Clod\" vira \"Claude\".")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            let e = Vocabulary.userEntries()
            terms = e.terms
            swaps = e.replacements.map { Swap(from: $0.from, to: $0.to) }
        }
    }

    private func addTerm() {
        let t = newTerm.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !terms.contains(t) else { return }
        terms.insert(t, at: 0)
        newTerm = ""
        save()
    }

    private func addSwap() {
        let f = newFrom.trimmingCharacters(in: .whitespaces), t = newTo.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return }
        swaps.insert(Swap(from: f, to: t), at: 0)
        newFrom = ""; newTo = ""
        save()
    }

    private func save() { Vocabulary.save(terms: terms, replacements: swaps.map { ($0.from, $0.to) }) }
}

// MARK: - Ajustes

private struct SettingsView: View {
    @State private var config = Config.load()
    @State private var hooks = AgentHook.isInstalled
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var profiles = SpeakerProfiles.load().profiles.map(\.name)
    @State private var notionToken = Keychain.get(Keychain.notionToken) ?? ""
    @State private var slackWebhook = Keychain.get(Keychain.slackWebhook) ?? ""
    @State private var slackBot = Keychain.get(Keychain.slackBotToken) ?? ""

    private let languages = [("pt", "Português"), ("en", "Inglês"), ("es", "Espanhol"), ("fr", "Francês"), ("de", "Alemão"), ("it", "Italiano")]

    var body: some View {
        Form {
            Section("Você") {
                TextField("Seu nome nas calls", text: $config.myName)
                Picker("Idioma principal", selection: $config.language) {
                    ForEach(languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                LabeledContent("Também falo") {
                    HStack {
                        ForEach(languages.filter { $0.0 != config.language }, id: \.0) { lang in
                            Toggle(lang.1, isOn: Binding(get: { config.otherLanguages.contains(lang.0) }, set: { on in
                                config.otherLanguages.removeAll { $0 == lang.0 }
                                if on { config.otherLanguages.append(lang.0) }
                            }))
                            .toggleStyle(.button)
                        }
                    }
                }
            }
            Section("Ditado") {
                Picker("IA dos modos", selection: $config.polishEngine) {
                    Text("Local (1–2 s, sem internet)").tag("local")
                    Text("Claude (5–10 s, usa a assinatura)").tag("claude")
                }
                Toggle("Pausar música enquanto dito", isOn: $config.pauseMedia)
                Toggle("Avisos do Claude Code na pílula", isOn: $hooks)
                    .onChange(of: hooks) { try? AgentHook.setInstalled(hooks); hooks = AgentHook.isInstalled }
            }
            Section("Calls") {
                Picker("Destino das notas", selection: $config.noteDestination) {
                    Text("Pasta de Markdown (Obsidian…)").tag("markdown")
                    Text("Notion").tag("notion")
                }
                if config.noteDestination == "notion" {
                    SecureField("Token da integração do Notion", text: $notionToken)
                        .onSubmit { Keychain.set(Keychain.notionToken, notionToken) }
                    TextField("ID ou link do banco do Notion", text: $config.notionDatabaseID)
                } else {
                    LabeledContent("Pasta") {
                        HStack {
                            Text(vaultName).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            Button("Escolher…") { chooseVault() }
                        }
                    }
                    TextField("Subpasta das notas de call", text: $config.callsFolder)
                    Toggle("Commit + push da nota (se a pasta for um repositório git)", isOn: $config.gitPush)
                }
                Toggle("Resumir com o Claude", isOn: $config.summarizeWithClaude)
                LabeledContent("Rigor no reconhecimento de vozes") {
                    Slider(value: $config.speakerMatchThreshold, in: 0.4...0.85) {
                        EmptyView()
                    } minimumValueLabel: { Text("solto").font(.caption) } maximumValueLabel: { Text("rígido").font(.caption) }
                }
            }
            Section("Slack") {
                Toggle("Postar o resumo da call no Slack", isOn: $config.slackEnabled)
                if config.slackEnabled {
                    SecureField("Incoming webhook (ou deixe vazio e use o bot)", text: $slackWebhook)
                        .onSubmit { Keychain.set(Keychain.slackWebhook, slackWebhook) }
                    SecureField("Token do bot (xoxb-…)", text: $slackBot)
                        .onSubmit { Keychain.set(Keychain.slackBotToken, slackBot) }
                    TextField("Canal do bot (ex.: #reunioes ou C0123…)", text: $config.slackChannel)
                    Text("Tokens ficam no Keychain do Mac. Enter salva; vazio + Enter apaga.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Vozes conhecidas") {
                if profiles.isEmpty {
                    Text("Nenhuma ainda. Depois de uma call, use Nomear falantes.").foregroundStyle(.secondary)
                }
                ForEach(profiles, id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        Button("Esquecer") {
                            var p = SpeakerProfiles.load()
                            p.profiles.removeAll { $0.name == name }
                            p.save()
                            profiles = p.profiles.map(\.name)
                        }
                    }
                }
            }
            Section("Sistema") {
                Toggle("Sincronizar com o iCloud", isOn: $config.syncICloud)
                    .help("Histórico, áudio dos ditados, modos, vocabulário e vozes ficam no iCloud Drive (pasta Hermes). Vale ao reabrir o Hermes.")
                Toggle("Abrir ao iniciar o Mac", isOn: $login)
                    .onChange(of: login) {
                        try? login ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        login = SMAppService.mainApp.status == .enabled
                    }
                LabeledContent("Versão", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                HStack {
                    Button("Abrir pasta de dados") { NSWorkspace.shared.open(Config.dataDir) }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: config.myName) { config.save() }
        .onChange(of: config.language) { config.save() }
        .onChange(of: config.otherLanguages) { config.save() }
        .onChange(of: config.syncICloud) { config.save() }
        .onChange(of: config.polishEngine) { config.save() }
        .onChange(of: config.pauseMedia) { config.save() }
        .onChange(of: config.vaultPath) { config.save() }
        .onChange(of: config.noteDestination) { config.save() }
        .onChange(of: config.notionDatabaseID) { config.save() }
        .onChange(of: config.slackEnabled) { config.save() }
        .onChange(of: config.slackChannel) { config.save() }
        .onDisappear {
            Keychain.set(Keychain.notionToken, notionToken)
            Keychain.set(Keychain.slackWebhook, slackWebhook)
            Keychain.set(Keychain.slackBotToken, slackBot)
        }
        .onChange(of: config.callsFolder) { config.save() }
        .onChange(of: config.summarizeWithClaude) { config.save() }
        .onChange(of: config.gitPush) { config.save() }
        .onChange(of: config.speakerMatchThreshold) { config.save() }
    }

    private var vaultName: String { (config.vaultPath as NSString).abbreviatingWithTildeInPath }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: config.vaultPath)
        if panel.runModal() == .OK, let url = panel.url { config.vaultPath = url.path }
    }
}

// MARK: - Modos

private struct ModesView: View {
    @ObservedObject private var store = ModeStore.shared
    @State private var selected: UUID?

    var body: some View {
        HSplitView {
            List(selection: $selected) {
                ForEach(store.modes) { m in
                    Label(m.name, systemImage: m.symbol).tag(m.id)
                }
            }
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 260)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button { addMode() } label: { Image(systemName: "plus") }.help("Novo modo")
                    Button { removeSelected() } label: { Image(systemName: "minus") }
                        .help("Excluir modo")
                        .disabled(selected == nil || store.modes.count <= 1)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(10)
                .background(.bar)
            }

            if let i = store.modes.firstIndex(where: { $0.id == selected }) {
                ModeEditor(mode: $store.modes[i])
                    .id(store.modes[i].id)
            } else {
                Text("Escolha um modo ou crie um novo com +").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selected == nil { selected = store.modes.first?.id } }
    }

    private func addMode() {
        let m = DictationMode(name: "Novo modo", symbol: "wand.and.stars", instructions: """
        Você recebe um ditado. Corrija erros de transcrição e vícios de fala, mantendo as palavras de quem falou.
        Responda apenas com o texto final, sem aspas.
        """, polish: true)
        store.modes.append(m)
        selected = m.id
    }

    private func removeSelected() {
        guard let selected, store.modes.count > 1 else { return }
        let wasDefault = store.modes.first { $0.id == selected }?.isDefault == true
        store.modes.removeAll { $0.id == selected }
        if wasDefault, !store.modes.isEmpty { store.modes[store.modes.count - 1].isDefault = true }
        if store.pinned == selected { store.pinned = nil }
        self.selected = store.modes.first?.id
    }
}

private struct ModeEditor: View {
    @Binding var mode: DictationMode
    @ObservedObject private var store = ModeStore.shared
    @State private var newSite = ""

    private static let symbols = ["mic.fill", "sparkle", "bubble.left.fill", "envelope.fill", "globe", "doc.text", "list.bullet",
                                  "pencil", "wand.and.stars", "briefcase.fill", "person.2.fill", "terminal", "note.text", "megaphone.fill"]

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        Form {
            Section {
                TextField("Nome", text: $mode.name)
                Picker("Ícone", selection: $mode.symbol) {
                    ForEach(Self.symbols, id: \.self) { Image(systemName: $0).tag($0) }
                }
                Toggle("Usar quando nenhum outro modo se aplica", isOn: Binding(get: { mode.isDefault }, set: { on in
                    guard on else { return }
                    for i in store.modes.indices { store.modes[i].isDefault = store.modes[i].id == mode.id }
                }))
            }
            Section {
                Toggle("Passar pela IA antes de colar", isOn: $mode.polish)
                Picker("Escrever em", selection: $mode.translateTo) {
                    Text("Mesmo idioma que falei").tag(String?.none)
                    ForEach(DictationMode.languages, id: \.0) { Text($0.1).tag(String?.some($0.0)) }
                }
                TextEditor(text: $mode.instructions)
                    .font(.system(size: 12))
                    .frame(height: 150)
                    .disabled(!mode.polish && mode.translateTo == nil)
            } header: {
                Text("O que fazer com o texto")
            } footer: {
                Text("Instruções para a IA. Traduzir sempre passa pela IA. Números e datas viram algarismos em qualquer modo.")
            }
            Section {
                ForEach(mode.apps, id: \.self) { id in
                    HStack {
                        Text(appName(id))
                        Spacer()
                        Button { mode.apps.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                Menu("Adicionar app aberto") {
                    ForEach(runningApps, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier!) {
                            if let id = app.bundleIdentifier, !mode.apps.contains(id) { mode.apps.append(id) }
                        }
                    }
                }
                ForEach(mode.sites, id: \.self) { site in
                    HStack {
                        Label(site, systemImage: "link")
                        Spacer()
                        Button { mode.sites.removeAll { $0 == site } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Site (ex.: mail.google.com)", text: $newSite).onSubmit(addSite)
                    Button("Adicionar", action: addSite).disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Liga sozinho em")
            } footer: {
                Text("Sites valem no Safari, Chrome, Arc e outros navegadores. Pelo menu do Hermes dá para fixar um modo.")
            }
        }
        .formStyle(.grouped)
    }

    private func addSite() {
        let s = newSite.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        guard !s.isEmpty, !mode.sites.contains(s) else { return }
        mode.sites.append(s)
        newSite = ""
    }

    private func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }
}
