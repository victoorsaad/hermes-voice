import AppKit

/// Cola o texto no app em foco via ⌘V e devolve o clipboard anterior.
enum Paster {
    /// Cola no app em foco. Sem permissão de Acessibilidade não dá para simular ⌘V:
    /// o texto fica no clipboard e a função devolve false.
    @discardableResult
    static func paste(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        Log.write("colar, acessibilidade=\(AXIsProcessTrusted()), app=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        guard AXIsProcessTrusted() else {
            pb.clearContents()
            pb.setString(text, forType: .string)
            return false
        }
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        let src = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let previous else { return }
            pb.clearContents()
            pb.setString(previous, forType: .string)
        }
        return true
    }

    /// Necessário para postar ⌘V e para ouvir a tecla global.
    static func ensureAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
