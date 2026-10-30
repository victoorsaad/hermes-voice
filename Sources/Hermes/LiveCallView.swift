import AppKit
import SwiftUI

/// Fundo de vidro da janela da call: Liquid Glass no macOS 26+, material HUD antes disso.
enum Glass {
    static func wrap(_ content: NSView, cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            // Vidro transparente (o fundo aparece quase sem desfoque) com véu escuro para o texto branco continuar legível.
            glass.style = .clear
            glass.tintColor = NSColor.black.withAlphaComponent(0.5)
            glass.contentView = content
            return glass
        }
        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = cornerRadius
        fx.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: fx.leadingAnchor), content.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            content.topAnchor.constraint(equalTo: fx.topAnchor), content.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        return fx
    }
}

/// Janela da call ao vivo: transcrição rolando em cima, chat com o Claude embaixo. Mesmo visual da pílula.
struct LiveCallView: View {
    @ObservedObject var call: LiveCall
    let config: () -> Config
    let close: () -> Void
    @State private var question = ""

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if call.lines.isEmpty && call.partials.values.allSatisfy(\.isEmpty) {
                            Text(call.running ? "Ouvindo… a transcrição aparece aqui em alguns segundos." : "Nenhuma call em andamento.")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.5))
                                .padding(.top, 4)
                        }
                        ForEach(call.lines) { line in
                            LineView(time: CallPipeline.timestamp(line.start), speaker: line.speaker, text: line.text,
                                     mine: line.speaker == call.myName, partial: false)
                        }
                        ForEach(call.partials.keys.sorted(), id: \.self) { who in
                            if let text = call.partials[who], !text.isEmpty {
                                LineView(time: "agora", speaker: who, text: text, mine: who == call.myName, partial: true)
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .scrollIndicators(.never)
                .onChange(of: call.lines.count) { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: call.partials) { proxy.scrollTo("end", anchor: .bottom) }
            }

            if !call.messages.isEmpty || call.thinking {
                separator
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(call.messages) { m in
                                Text(m.text)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.95))
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(m.fromMe ? 0.16 : 0.07)))
                                    .frame(maxWidth: .infinity, alignment: m.fromMe ? .trailing : .leading)
                            }
                            if call.thinking {
                                Text("Claude pensando…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                            }
                            Color.clear.frame(height: 1).id("chatEnd")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: 220)
                    .onChange(of: call.messages.count) { proxy.scrollTo("chatEnd", anchor: .bottom) }
                }
            }

            input
        }
        .frame(minWidth: 320, minHeight: 280)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(call.running ? Color.red : Color.white.opacity(0.3))
                .frame(width: 8, height: 8)
            Text(call.running ? "Call" : "Call encerrada")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            if call.running, let start = call.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Self.elapsed(ctx.date.timeIntervalSince(start)))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help("Esconder (a call continua gravando)")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var separator: some View {
        Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5)
    }

    private var input: some View {
        let empty = question.trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(spacing: 6) {
            TextField("Pergunte sobre a call…", text: $question)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(empty || call.thinking ? .white.opacity(0.35) : .black)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(empty || call.thinking ? .white.opacity(0.12) : .white))
            }
            .buttonStyle(.plain)
            .disabled(empty || call.thinking)
        }
        .padding(.leading, 14)
        .padding(.trailing, 5)
        .frame(height: 36)
        .background(Capsule().fill(.black.opacity(0.35)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.13), lineWidth: 0.5))
        .padding(12)
    }

    private static func elapsed(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func send() {
        guard !question.trimmingCharacters(in: .whitespaces).isEmpty, !call.thinking else { return }
        call.ask(question, config: config())
        question = ""
    }
}

private struct LineView: View {
    let time: String
    let speaker: String
    let text: String
    let mine: Bool
    let partial: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(speaker)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(mine ? Color.white.opacity(0.75) : Color.orange)
                Text(time)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
            }
            Text(text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .foregroundStyle(.white.opacity(partial ? 0.55 : 0.92))
                .italic(partial)
        }
    }
}
