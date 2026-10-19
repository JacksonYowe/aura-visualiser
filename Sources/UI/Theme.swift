import SwiftUI

/// Design tokens, translated for SwiftUI.
enum Tokens {
    static let bg = Color(hex: 0x07070A)
    static let surface = Color(hex: 0x0D0D12)
    static let surface2 = Color(hex: 0x15151C)
    static let surface3 = Color(hex: 0x1F1F28)
    static let ink = Color(hex: 0xF5F1EA)
    static let inkDim = ink.opacity(0.62)
    static let inkFaint = ink.opacity(0.14)
    static let line = ink.opacity(0.10)
    static let accent = Color(hex: 0x7DF9FF)
    static let accent2 = Color(hex: 0xB8B4FF)
    static let accent3 = Color(hex: 0xFF5A8C)

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Manrope", size: size).weight(weight)
    }
    static func serif(_ size: CGFloat, italic: Bool = false) -> Font {
        .custom(italic ? "InstrumentSerif-Italic" : "InstrumentSerif-Regular", size: size)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("JetBrains Mono", size: size).weight(weight)
    }

    static let ease = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.5)
    static let easeSlow = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.9)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// Mono, uppercase, tracked-out label — a small tracked-out label.
struct Eyebrow: View {
    let text: String
    var color: Color = Tokens.inkDim
    init(_ text: String, color: Color = Tokens.inkDim) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased())
            .font(Tokens.mono(10, .medium))
            .tracking(1.6)
            .foregroundStyle(color)
    }
}

/// Dark glass panel with a hairline border.
struct GlassPanel: ViewModifier {
    var radius: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Tokens.surface.opacity(0.82))
            }
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Tokens.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
    }
}

extension View {
    func glassPanel(radius: CGFloat = 20) -> some View { modifier(GlassPanel(radius: radius)) }
}

/// Round icon button used for transport controls.
struct IconButton: View {
    let symbol: String
    var size: CGFloat = 34
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(prominent ? Tokens.bg : Tokens.ink)
                .frame(width: size, height: size)
                .background(Circle().fill(prominent ? Tokens.ink : (hovering ? Tokens.inkFaint : Color.clear)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering ? 1.06 : 1)
        .animation(Tokens.ease, value: hovering)
        .onHover { hovering = $0 }
    }
}
