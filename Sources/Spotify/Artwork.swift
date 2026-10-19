import AppKit
import CryptoKit
import Foundation
import simd

/// A decoded album cover plus the colours pulled out of it.
struct Artwork {
    let image: CGImage
    let palette: Palette
    let key: String
}

/// Four colours that drive every visual mode.
struct Palette: Equatable {
    var primary: SIMD3<Float>     // the cover's main colour
    var secondary: SIMD3<Float>   // a contrasting colour from the cover
    var accent: SIMD3<Float>      // the most vivid colour
    var shadow: SIMD3<Float>      // a deep tone for backgrounds

    static let aura = Palette(primary: SIMD3(0.49, 0.98, 1.0),
                              secondary: SIMD3(0.72, 0.70, 1.0),
                              accent: SIMD3(1.0, 0.35, 0.55),
                              shadow: SIMD3(0.03, 0.03, 0.05))

    func mixed(to other: Palette, _ t: Float) -> Palette {
        Palette(primary: simd_mix(primary, other.primary, SIMD3(repeating: t)),
                secondary: simd_mix(secondary, other.secondary, SIMD3(repeating: t)),
                accent: simd_mix(accent, other.accent, SIMD3(repeating: t)),
                shadow: simd_mix(shadow, other.shadow, SIMD3(repeating: t)))
    }
}

final class ArtworkLoader: @unchecked Sendable {
    private let memory = NSCache<NSString, CGImageBox>()
    private let session: URLSession
    private let cacheDir: URL

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
        cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.aura.Aura/Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        memory.countLimit = 40
    }

    /// Loads the cover for a track. Falls back to Spotify's public oEmbed lookup
    /// when the desktop app doesn't report an artwork URL.
    func load(track: SpotifyClient.Track) async -> Artwork? {
        var urlString = track.artworkURL
        if urlString.isEmpty, let oembed = await oEmbedThumbnail(for: track.id) { urlString = oembed }
        guard let url = URL(string: urlString), !urlString.isEmpty else { return nil }
        guard let image = await image(at: url) else { return nil }
        return Artwork(image: image, palette: PaletteExtractor.extract(from: image), key: urlString)
    }

    private func image(at url: URL) async -> CGImage? {
        let key = url.absoluteString as NSString
        if let hit = memory.object(forKey: key) { return hit.image }

        let file = cacheDir.appendingPathComponent(Self.hash(url.absoluteString))
        var data = try? Data(contentsOf: file)
        if data == nil {
            guard let (fresh, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            data = fresh
            try? fresh.write(to: file, options: .atomic)
        }
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        memory.setObject(CGImageBox(image), forKey: key)
        return image
    }

    private func oEmbedThumbnail(for trackID: String) async -> String? {
        // "spotify:track:abc" → https://open.spotify.com/track/abc
        let parts = trackID.split(separator: ":")
        guard parts.count == 3, parts[1] == "track" else { return nil }
        var comps = URLComponents(string: "https://open.spotify.com/oembed")!
        comps.queryItems = [URLQueryItem(name: "url", value: "https://open.spotify.com/track/\(parts[2])")]
        guard let url = comps.url,
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var thumb = json["thumbnail_url"] as? String,
              URL(string: thumb)?.scheme?.lowercased() == "https" else { return nil }
        // Ask Spotify's image CDN for the 640px rendition instead of 300px.
        thumb = thumb.replacingOccurrences(of: "ab67616d00001e02", with: "ab67616d0000b273")
        return thumb
    }

    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

// MARK: - Palette extraction

enum PaletteExtractor {
    /// k-means over a 40×40 thumbnail, then picks roles by population and vividness.
    static func extract(from image: CGImage) -> Palette {
        let side = 40
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .aura }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        var points: [SIMD3<Float>] = []
        points.reserveCapacity(side * side)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            points.append(SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2])) / 255)
        }

        // Deterministic farthest-point seeding.
        let k = 6
        var centers: [SIMD3<Float>] = [points.reduce(.zero, +) / Float(points.count)]
        while centers.count < k {
            var best = points[0], bestD: Float = -1
            for p in points {
                let d = centers.map { simd_distance_squared($0, p) }.min()!
                if d > bestD { bestD = d; best = p }
            }
            centers.append(best)
        }
        var counts = [Int](repeating: 0, count: k)
        for _ in 0..<12 {
            var sums = [SIMD3<Float>](repeating: .zero, count: k)
            counts = [Int](repeating: 0, count: k)
            for p in points {
                var bi = 0, bd = Float.greatestFiniteMagnitude
                for (ci, c) in centers.enumerated() {
                    let d = simd_distance_squared(c, p)
                    if d < bd { bd = d; bi = ci }
                }
                sums[bi] += p
                counts[bi] += 1
            }
            for ci in 0..<k where counts[ci] > 0 { centers[ci] = sums[ci] / Float(counts[ci]) }
        }

        struct Swatch { var rgb: SIMD3<Float>; var share: Float; var hsv: SIMD3<Float> }
        let total = Float(points.count)
        let swatches = (0..<k).filter { counts[$0] > 0 }.map {
            Swatch(rgb: centers[$0], share: Float(counts[$0]) / total, hsv: hsv(centers[$0]))
        }
        guard !swatches.isEmpty else { return .aura }

        let vivid: (Swatch) -> Float = { $0.hsv.y * $0.hsv.z }
        let monochrome = swatches.allSatisfy { $0.hsv.y < 0.12 }

        let primary = swatches.max {
            ($0.share * (0.25 + vivid($0)) * ($0.hsv.z > 0.12 ? 1 : 0.2)) <
            ($1.share * (0.25 + vivid($1)) * ($1.hsv.z > 0.12 ? 1 : 0.2))
        }!
        let accent = swatches.max { vivid($0) + $0.share * 0.2 < vivid($1) + $1.share * 0.2 }!
        let secondary = swatches.filter { $0.rgb != primary.rgb }.max {
            hueDistance($0.hsv.x, primary.hsv.x) * (0.3 + $0.share) * (0.2 + $0.hsv.z) <
            hueDistance($1.hsv.x, primary.hsv.x) * (0.3 + $1.share) * (0.2 + $1.hsv.z)
        } ?? accent
        let darkest = swatches.min { $0.hsv.z < $1.hsv.z }!

        func lift(_ s: Swatch, minS: Float, minV: Float) -> SIMD3<Float> {
            var h = s.hsv
            if !monochrome { h.y = max(h.y, minS) }
            h.z = max(h.z, minV)
            return rgb(h)
        }
        var shadowHSV = darkest.hsv
        shadowHSV.z = min(max(shadowHSV.z, 0.04), 0.16)
        shadowHSV.y = min(shadowHSV.y, 0.8)

        return Palette(primary: lift(primary, minS: 0.35, minV: 0.62),
                       secondary: lift(secondary, minS: 0.3, minV: 0.55),
                       accent: lift(accent, minS: 0.55, minV: 0.8),
                       shadow: rgb(shadowHSV))
    }

    private static func hueDistance(_ a: Float, _ b: Float) -> Float {
        let d = abs(a - b)
        return min(d, 1 - d) * 2 + 0.05
    }

    static func hsv(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let mx = max(c.x, c.y, c.z), mn = min(c.x, c.y, c.z), d = mx - mn
        var h: Float = 0
        if d > 1e-5 {
            if mx == c.x { h = (c.y - c.z) / d }
            else if mx == c.y { h = 2 + (c.z - c.x) / d }
            else { h = 4 + (c.x - c.y) / d }
            h = (h / 6).truncatingRemainder(dividingBy: 1)
            if h < 0 { h += 1 }
        }
        return SIMD3(h, mx > 0 ? d / mx : 0, mx)
    }

    static func rgb(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let h = c.x * 6, s = c.y, v = c.z
        let i = floor(h), f = h - i
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch Int(i) % 6 {
        case 0: return SIMD3(v, t, p)
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, t)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(t, p, v)
        default: return SIMD3(v, p, q)
        }
    }
}
