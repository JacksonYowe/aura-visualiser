import Foundation

/// How the words of a song are drawn.
enum LyricTheme: Int, CaseIterable, Identifiable {
    case bubbles, karaoke, neon, cinema, embers, stickers

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .bubbles: "Bubbles"
        case .karaoke: "Karaoke"
        case .neon: "Neon"
        case .cinema: "Cinema"
        case .embers: "Embers"
        case .stickers: "Stickers"
        }
    }

    var blurb: String {
        switch self {
        case .bubbles: "Each word floats up in a glass bubble"
        case .karaoke: "The line waits, words light up as they're sung"
        case .neon: "Words buzz on like neon signs"
        case .cinema: "Big serif words drift in like film titles"
        case .embers: "Words ignite and burn away into sparks"
        case .stickers: "Words slap on like stickers"
        }
    }

    /// PostScript name of the font drawn into the text atlas.
    var fontName: String {
        switch self {
        case .bubbles: "Manrope-Bold"
        case .neon: "Manrope-SemiBold"
        case .cinema: "InstrumentSerif-Italic"
        case .karaoke, .embers, .stickers: "Manrope-ExtraBold"
        }
    }

    var uppercase: Bool { self == .stickers }

    /// Text height as a fraction of the screen height.
    var textHeight: Float {
        switch self {
        case .bubbles: 0.05
        case .cinema: 0.098
        case .neon: 0.07
        default: 0.066
        }
    }

    /// Horizontal space between words (screen-height units).
    var gap: Float {
        switch self {
        case .bubbles: 0.014
        case .stickers: 0.03
        case .cinema: 0.02
        default: 0.024
        }
    }

    /// Shows the whole line up front and highlights words as they're sung.
    var showsWholeLine: Bool { self == .karaoke }

    /// Seconds a word takes to disappear when its line ends.
    var popDuration: Double {
        switch self {
        case .bubbles: 0.22
        case .karaoke: 0.3
        case .neon: 0.28
        case .cinema: 0.55
        case .embers: 0.7
        case .stickers: 0.2
        }
    }

    /// How far ahead of the singer a word starts to appear, so it's readable ~0.1 s before it's sung.
    /// Styles with a slower entrance start a little earlier.
    var appearLead: Double {
        switch self {
        case .bubbles: 0.13
        case .karaoke, .stickers: 0.1
        case .neon: 0.18
        case .cinema: 0.2
        case .embers: 0.17
        }
    }

    var vertexFunction: String { self == .bubbles ? "vBubble" : "vLyricText" }
    var fragmentFunction: String { self == .bubbles ? "fBubble" : "fLyric\(title)" }
}
