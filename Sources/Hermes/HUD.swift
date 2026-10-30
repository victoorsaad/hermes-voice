import Carbon.HIToolbox
import AppKit
import SwiftUI

/// Estado da pílula flutuante (base da tela, estilo "mini recorder").
@MainActor
final class HUDModel: ObservableObject {
    enum Kind { case listening, processing, suggestion }

    @Published var kind: Kind = .listening
    @Published var symbol = "mic.fill"
    @Published var tint = Color.white
    @Published var title = ""
    @Published var detail = ""
    @Published var showControls = false
    @Published var levels = [CGFloat](repeating: 0, count: 26)
    /// Texto ao vivo do ditado, mostrado numa caixa acima da pílula.
    @Published var liveText = ""
    /// Ícone do botão de ação (padrão: parar).
    @Published var actionSymbol: String?

    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Arrastar a pílula (vale até ela sumir) e clique duplo para voltar ao centro.
    var onDrag: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var onResetPosition: (() -> Void)?

    func push(level: CGFloat) {
        levels.removeFirst()
        levels.append(min(1, max(0, level)))
    }

    func resetLevels() { levels = [CGFloat](repeating: 0, count: levels.count) }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack(spacing: 8) {
            if !model.liveText.isEmpty {
                Text(model.liveText)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .lineLimit(6)
                    .truncationMode(.head)
                    .multilineTextAlignment(.leading)
                    .frame(width: 460, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.94)))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.13), lineWidth: 0.5))
            }
            pill
        }
        .padding(10)
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { _ in model.onDrag?() }
            .onEnded { _ in model.onDragEnd?() })
        .onTapGesture(count: 2) { model.onResetPosition?() }
    }

    private var pill: some View {
        HStack(spacing: 10) {
            Image(systemName: model.symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(model.tint)
                .frame(width: 14)

            switch model.kind {
            case .listening: Waveform(levels: model.levels, tint: model.tint)
            case .processing: Thinking(count: model.levels.count)
            case .suggestion: EmptyView()
            }

            if !model.title.isEmpty {
                Text(model.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(model.kind == .suggestion ? 0.95 : 0.7))
                    .lineLimit(1)
            }
            if !model.detail.isEmpty {
                Text(model.detail)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
            }
            if model.showControls {
                HStack(spacing: 6) {
                    if let stop = model.onStop {
                        RoundButton(symbol: model.actionSymbol ?? (model.kind == .suggestion ? "record.circle" : "stop.fill"),
                                    tint: model.actionSymbol != nil ? .white : (model.kind == .suggestion ? .red : .white), action: stop)
                    }
                    if let cancel = model.onCancel {
                        RoundButton(symbol: "xmark", tint: .white.opacity(0.6), action: cancel)
                    }
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, model.showControls ? 6 : 16)
        .frame(height: 40)
        .background(Capsule().fill(Color.black.opacity(0.94)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.13), lineWidth: 0.5))
        .fixedSize()
    }
}

/// Barras que seguem o volume do mic, a mais recente à direita.
private struct Waveform: View {
    let levels: [CGFloat]
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(tint.opacity(0.35 + 0.65 * Double(i) / Double(levels.count)))
                    .frame(width: 2.5, height: 3 + levels[i] * 21)
            }
        }
        .frame(height: 24)
        .animation(.easeOut(duration: 0.09), value: levels)
    }
}

/// Mesmas barras, respirando em onda enquanto transcreve.
private struct Thinking: View {
    let count: Int

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<count, id: \.self) { i in
                    let phase = sin(t * 5 - Double(i) * 0.45)
                    Capsule()
                        .fill(Color.white.opacity(0.25 + 0.35 * (phase + 1) / 2))
                        .frame(width: 2.5, height: 4 + CGFloat((phase + 1) / 2) * 9)
                }
            }
            .frame(height: 24)
        }
    }
}

private struct RoundButton: View {
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

/// Janela sem foco que flutua sobre tudo (inclusive tela cheia), na base da tela ou onde você arrastou até ela sumir.
@MainActor
final class HUD {
    let model = HUDModel()
    private let panel: NSPanel
    private let host: NSHostingView<HUDView>
    private var hideWork: DispatchWorkItem?
    /// Base-centro da pílula escolhida arrastando; nil = centralizada na base da tela do mouse.
    /// Some junto com a pílula: a próxima gravação começa no lugar padrão.
    private var anchor: NSPoint?
    private var dragStart: (mouse: NSPoint, anchor: NSPoint)?

    init() {
        host = NSHostingView(rootView: HUDView(model: model))
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = host
        model.onDrag = { [weak self] in self?.drag() }
        model.onDragEnd = { [weak self] in self?.endDrag() }
        model.onResetPosition = { [weak self] in self?.resetPosition() }
    }

    private func drag() {
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, NSPoint(x: panel.frame.midX, y: panel.frame.minY)) }
        guard let start = dragStart else { return }
        anchor = NSPoint(x: start.anchor.x + mouse.x - start.mouse.x, y: start.anchor.y + mouse.y - start.mouse.y)
        layout()
    }

    private func endDrag() {
        dragStart = nil
        // Guarda onde ficou de fato (layout prende dentro da tela).
        anchor = NSPoint(x: panel.frame.midX, y: panel.frame.minY)
    }

    private func resetPosition() {
        anchor = nil
        layout()
    }

    var isVisible: Bool { panel.isVisible }

    /// Aplica um estado e mostra a pílula. `autoHide` some sozinho depois de N segundos.
    /// `fade: false` aparece de uma vez (o ditado liga o mic logo em seguida e prenderia a animação).
    func show(autoHide: TimeInterval? = nil, fade: Bool = true, _ configure: (HUDModel) -> Void) {
        hideWork?.cancel()
        model.actionSymbol = nil
        configure(model)
        layout()
        if !panel.isVisible {
            panel.alphaValue = fade ? 0 : 1
            panel.orderFrontRegardless()
            if fade { NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 } }
        } else if panel.alphaValue < 1 {
            // Estava sumindo (hide em andamento): volta inteira.
            panel.alphaValue = 1
        }
        if let autoHide {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: work)
        }
    }

    func hide() {
        hideWork?.cancel()
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; panel.animator().alphaValue = 0 }) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel.alphaValue == 0 else { return }
                self.panel.orderOut(nil)
                self.anchor = nil
                self.model.liveText = ""
                self.model.onStop = nil
                self.model.onCancel = nil
            }
        }
    }

    /// Reposiciona após mudar texto/botões: onde você deixou, ou centralizado na base da tela onde está o mouse.
    /// A base fica parada; o texto ao vivo cresce para cima.
    func layout() {
        let size = host.fittingSize
        let mouse = NSEvent.mouseLocation
        let base: NSPoint
        let screen: NSScreen
        if let anchor, let s = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) {
            screen = s
            base = anchor
        } else {
            screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
            base = NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.minY + 14)
        }
        let f = screen.visibleFrame
        let x = min(max(base.x - size.width / 2, f.minX), f.maxX - size.width)
        let y = min(max(base.y, f.minY), f.maxY - size.height)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

/// Atalho global via Carbon: funciona em qualquer app e não depende de Acessibilidade.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data else { return noErr }
            Unmanaged<HotKey>.fromOpaque(data).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, me, &handler)
        let id = EventHotKeyID(signature: OSType(0x484D5352), id: 1) // "HMSR"
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
