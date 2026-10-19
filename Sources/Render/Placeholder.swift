import AppKit
import CoreGraphics

/// The artwork shown when nothing is playing — drawn in the app's palette so idle Aura still looks good.
enum Placeholder {
    static let cover: CGImage = draw(side: 640)

    private static func draw(side: Int) -> CGImage {
        let s = CGFloat(side)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

        func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: a)
        }
        ctx.setFillColor(rgb(0x07070A))
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

        func glow(_ hex: UInt32, x: CGFloat, y: CGFloat, radius: CGFloat, alpha: CGFloat) {
            let g = CGGradient(colorsSpace: space, colors: [rgb(hex, alpha), rgb(hex, 0)] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: x * s, y: y * s), startRadius: 0,
                                   endCenter: CGPoint(x: x * s, y: y * s), endRadius: radius * s, options: [])
        }
        glow(0x7DF9FF, x: 0.32, y: 0.62, radius: 0.62, alpha: 0.85)
        glow(0xB8B4FF, x: 0.74, y: 0.30, radius: 0.55, alpha: 0.8)
        glow(0xFF5A8C, x: 0.78, y: 0.78, radius: 0.30, alpha: 0.7)
        glow(0x07070A, x: 0.5, y: 0.5, radius: 0.22, alpha: 0.9)

        // Concentric rings, like grooves on a record.
        ctx.setLineWidth(1.2)
        for i in 0..<14 {
            let r = s * (0.08 + CGFloat(i) * 0.03)
            ctx.setStrokeColor(rgb(0xF5F1EA, 0.05 + 0.02 * CGFloat(i % 3)))
            ctx.strokeEllipse(in: CGRect(x: s / 2 - r, y: s / 2 - r, width: r * 2, height: r * 2))
        }

        // Wordmark.
        let font = NSFont(name: "InstrumentSerif-Italic", size: s * 0.16) ?? NSFont.systemFont(ofSize: s * 0.14)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0.96, alpha: 0.92)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Aura", attributes: attrs))
        ctx.textPosition = CGPoint(x: s * 0.07, y: s * 0.08)
        CTLineDraw(line, ctx)

        return ctx.makeImage()!
    }
}
