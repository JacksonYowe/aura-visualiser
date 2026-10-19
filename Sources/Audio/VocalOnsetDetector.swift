import Foundation

/// Estimates whether someone is singing right now (0…1).
///
/// A voice is a steady, pitched sound in the middle of the stereo mix, mostly between 375 Hz and
/// 3.5 kHz. So it keeps only energy that is (a) centred — mid louder than side, (b) steady —
/// a median over time beats a median across frequency, which strips drum hits — and compares it
/// with all the energy in that band. That share goes up when the singer comes in. Its range is
/// learned per song, because every mix is different.
final class VocalActivityDetector {
    static let loBin = 8, hiBin = 75                   // ≈375 Hz – 3.5 kHz (1024 FFT, 48 kHz)
    var useCenter = true

    private let bins = hiBin - loBin
    private let depth = 9
    private var history: [Float]
    private var head = 0
    private var centred: [Float]
    private var window = [Float](repeating: 0, count: 9)

    private(set) var smoothed: Float = 0
    private(set) var lastVoiced: Float = 0
    private(set) var lastTotal: Float = 0
    private var recent: [Float] = []                   // ~20 s of ratio values, 12 per second
    private var decimate = 0
    private(set) var lowRef: Float = 0.1
    private(set) var highRef: Float = 0.5
    private var sinceRefresh = 0
    private(set) var activity: Float = 0

    init() {
        history = [Float](repeating: 0, count: depth * (Self.hiBin - Self.loBin))
        centred = [Float](repeating: 0, count: Self.hiBin - Self.loBin)
    }

    func reset() {
        for i in history.indices { history[i] = 0 }
        head = 0
        smoothed = 0
        activity = 0
        lastVoiced = 0
        lastTotal = 0
        recent.removeAll()
        decimate = 0
        sinceRefresh = 0
        lowRef = 0.1
        highRef = 0.5
    }

    /// Call once per analysis step with the mid (and side) magnitude spectra. Returns activity.
    func process(mid: UnsafeMutablePointer<Float>, side: UnsafeMutablePointer<Float>?, loud: Bool) -> Float {
        let lo = Self.loBin
        var total: Float = 0
        for b in 0..<bins {
            let m = mid[lo + b]
            total += m * m
            var c: Float = 1
            if useCenter, let side {
                let s = side[lo + b]
                let m2 = m * m
                c = max(0, m2 - s * s) / max(m2, 1e-12)
                c = c * c
            }
            centred[b] = m * c
            history[head * bins + b] = centred[b]
        }
        head = (head + 1) % depth

        var voiced: Float = 0
        for b in 0..<bins {
            for f in 0..<depth { window[f] = history[f * bins + b] }
            let steady = Self.median(&window, count: depth)
            for j in 0..<9 { window[j] = centred[min(max(b + j - 4, 0), bins - 1)] }
            let click = Self.median(&window, count: 9)
            let mask = steady * steady / (steady * steady + click * click + 1e-12)
            let h = centred[b] * mask
            voiced += h * h
        }

        lastVoiced = voiced
        lastTotal = total
        let ratio = loud ? voiced / max(total, 1e-9) : 0
        smoothed += (ratio - smoothed) * (ratio > smoothed ? 0.35 : 0.12)

        decimate += 1
        if decimate >= 16, loud {                       // ≈12 per second
            decimate = 0
            recent.append(smoothed)
            if recent.count > 240 { recent.removeFirst(recent.count - 240) }
            sinceRefresh += 1
            if sinceRefresh >= 6, recent.count >= 24 {
                sinceRefresh = 0
                let sorted = recent.sorted()
                lowRef = sorted[Int(Double(sorted.count - 1) * 0.2)]
                highRef = sorted[Int(Double(sorted.count - 1) * 0.85)]
            }
        }
        let span = max(highRef - lowRef, 0.04)
        activity = loud ? min(max((smoothed - lowRef) / span, 0), 1) : 0
        return activity
    }

    private static func median(_ v: inout [Float], count: Int) -> Float {
        for i in 1..<count {
            let x = v[i]
            var j = i - 1
            while j >= 0, v[j] > x { v[j + 1] = v[j]; j -= 1 }
            v[j + 1] = x
        }
        return v[count / 2]
    }
}
