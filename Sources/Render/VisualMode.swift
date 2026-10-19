import Foundation

enum VisualMode: Int, CaseIterable, Identifiable {
    case halo, kaleido, liquid, tunnel, mosaic, stardust, scope, skyline

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .halo: "Halo"
        case .kaleido: "Kaleido"
        case .liquid: "Liquid"
        case .tunnel: "Tunnel"
        case .mosaic: "Mosaic"
        case .stardust: "Stardust"
        case .scope: "Scope"
        case .skyline: "Skyline"
        }
    }

    var blurb: String {
        switch self {
        case .halo: "The cover, ringed by the spectrum"
        case .kaleido: "The cover folded into a kaleidoscope"
        case .liquid: "The cover melting with the music"
        case .tunnel: "A corridor tiled with the cover"
        case .mosaic: "The cover as a pulsing LED wall"
        case .stardust: "The cover as 32,000 particles"
        case .scope: "The sound wave, in the cover's colours"
        case .skyline: "Spectrum bars you see the cover through"
        }
    }

    var number: String { String(format: "%02d", rawValue + 1) }

    /// Fragment function for the full-screen pass.
    var fragmentName: String { self == .stardust ? "fStardustBackground" : "f\(title)" }

    func next(_ step: Int) -> VisualMode {
        let all = Self.allCases
        return all[(rawValue + step + all.count) % all.count]
    }
}
