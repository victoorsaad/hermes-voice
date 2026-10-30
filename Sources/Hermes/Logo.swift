import AppKit

/// Marca do Hermes: a asa do elmo do mensageiro, feita de penas arredondadas como as barras da pílula de áudio.
/// O mesmo desenho gera o ícone do app (fundo azul-noite, barras bronze) e o ícone da barra de menus (template).
enum Logo {
    static let night = (top: NSColor(srgbRed: 0.133, green: 0.251, blue: 0.416, alpha: 1),
                        bottom: NSColor(srgbRed: 0.075, green: 0.141, blue: 0.239, alpha: 1))
    static let bronze = (light: NSColor(srgbRed: 0.914, green: 0.780, blue: 0.494, alpha: 1),
                         dark: NSColor(srgbRed: 0.690, green: 0.478, blue: 0.231, alpha: 1))

    /// Penas empilhadas, de cima para baixo: início no "braço" da asa (x, y), comprimento e inclinação (graus).
    /// A de cima é a mais longa e mais erguida; as de baixo encurtam e deitam, como a asa do elmo do Hermes.
    private static let feathers: [(x: CGFloat, y: CGFloat, length: CGFloat, angle: CGFloat)] = [
        (0.07, 0.00, 1.00, 30), (0.01, -0.17, 0.87, 19), (0.00, -0.34, 0.73, 9), (0.04, -0.50, 0.59, 0), (0.12, -0.65, 0.45, -8),
    ]

    /// Caminhos das penas, centralizados e escalados para caber em `rect`.
    static func wingPaths(in rect: CGRect, width: CGFloat = 0.115) -> [CGPath] {
        var raw: [CGPath] = []
        for f in feathers {
            let feather = CGRect(x: 0, y: -width / 2, width: f.length, height: width)
            var t = CGAffineTransform(translationX: f.x, y: f.y).rotated(by: f.angle * .pi / 180)
            raw.append(CGPath(roundedRect: feather, cornerWidth: width / 2, cornerHeight: width / 2, transform: &t))
        }
        let box = raw.reduce(CGRect.null) { $0.union($1.boundingBoxOfPath) }
        let scale = min(rect.width / box.width, rect.height / box.height)
        var fit = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -box.midX, y: -box.midY)
        return raw.map { $0.copy(using: &fit)! }
    }

    static func drawWing(in rect: CGRect, width: CGFloat = 0.115, color: (CGContext, CGPath) -> Void, ctx: CGContext) {
        for path in wingPaths(in: rect, width: width) { color(ctx, path) }
    }

    /// Ícone do app no grid do macOS (squircle de 824/1024 com sombra).
    static func appIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = size / 1024
            let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
            let shape = CGPath(roundedRect: tile, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)

            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.addPath(shape)
            ctx.setFillColor(night.bottom.cgColor)
            ctx.fillPath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(shape)
            ctx.clip()
            let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [night.top.cgColor, night.bottom.cgColor] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
            // Brilho suave no alto, como luz sobre o mar Egeu.
            let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [NSColor.white.withAlphaComponent(0.10).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(glow, startCenter: CGPoint(x: tile.midX, y: tile.maxY), startRadius: 0,
                                   endCenter: CGPoint(x: tile.midX, y: tile.maxY), endRadius: 600 * s, options: [])

            let gold = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [bronze.light.cgColor, bronze.dark.cgColor] as CFArray, locations: [0, 1])!
            let wingRect = tile.insetBy(dx: 190 * s, dy: 190 * s)
            drawWing(in: wingRect, color: { c, path in
                c.saveGState()
                c.addPath(path)
                c.clip()
                c.drawLinearGradient(gold, start: CGPoint(x: 0, y: wingRect.maxY), end: CGPoint(x: 0, y: wingRect.minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                c.restoreGState()
            }, ctx: ctx)
            ctx.restoreGState()
            return true
        }
    }

    /// Ícone da barra de menus (template: o macOS pinta de preto/branco conforme o tema).
    static func menuBarIcon(recording: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Em 16 pt as penas precisam ser mais grossas para não sumirem.
            drawWing(in: rect.insetBy(dx: 1, dy: 0), width: 0.15, color: { c, path in
                c.addPath(path)
                c.setFillColor(NSColor.black.cgColor)
                c.fillPath()
            }, ctx: ctx)
            if recording {
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fillEllipse(in: CGRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 6, height: 6))
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Gera o .iconset (todos os tamanhos que o iconutil espera).
    static func writeIconset(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                appIcon(size: CGFloat(px)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
                NSGraphicsContext.restoreGraphicsState()
                try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
            }
        }
    }
}
