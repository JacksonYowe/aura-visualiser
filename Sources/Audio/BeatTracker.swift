import Accelerate
import Foundation

/// Finds the tempo and where the beats fall, from a stream of onset strengths.
/// Used to predict beats when there isn't enough look-ahead to wait for them.
final class BeatTracker {
    private let hop: Int
    private let rate: Double
    private let capacity = 1024                       // ≈ 5.5 s of history at 187.5 hops/s
    private var history: [Float]
    private var head = 0
    private var filled = 0
    private var newestEnd = 0                         // sample index at the end of the newest hop
    private var sinceUpdate = 0

    private(set) var period: Double = 0               // samples per beat
    private(set) var anchor: Double = 0               // sample index of a recent beat
    private(set) var confidence: Float = 0
    private var stableCount = 0
    private var lastLag: Double = 0
    /// Evidence that the real beat is twice as fast as the strongest correlation (−4…4).
    private var octaveBias = 0
    private var unclear = 0

    /// Samples between an onset and the peak it makes in the onset stream.
    let onsetOffset: Double

    init(hop: Int, rate: Double, onsetOffset: Double) {
        self.hop = hop
        self.rate = rate
        self.onsetOffset = onsetOffset
        history = [Float](repeating: 0, count: capacity)
    }

    var locked: Bool { confidence > 0.45 && period > 0 }
    /// Tests only.
    static var debug = false
    var bpm: Double { period > 0 ? 60 * rate / period : 0 }

    func reset() {
        history = [Float](repeating: 0, count: capacity)
        filled = 0; head = 0; confidence = 0; stableCount = 0; period = 0; octaveBias = 0; unclear = 0; lastLag = 0
    }

    func push(_ value: Float, hopEnd: Int) {
        history[head] = value
        head = (head + 1) % capacity
        filled = min(filled + 1, capacity)
        newestEnd = hopEnd
        sinceUpdate += 1
        if sinceUpdate >= 24, filled >= 700 {
            sinceUpdate = 0
            estimate()
        }
    }

    /// 0 at a beat, rising to 1 just before the next.
    func phase(at sample: Double) -> Double {
        guard period > 0 else { return 0 }
        let x = (sample - anchor) / period
        return x - floor(x)
    }

    /// The first beat strictly after `sample` on the current grid, locked or not.
    func gridBeat(after sample: Double) -> Double? {
        guard period > 0 else { return nil }
        return anchor + (floor((sample - anchor) / period) + 1) * period
    }

    /// The first beat strictly after `sample` (nil when not locked).
    func nextBeat(after sample: Double) -> Double? {
        guard locked else { return nil }
        let k = floor((sample - anchor) / period) + 1
        return anchor + k * period
    }

    /// Of the pulses spaced `lag` apart, how strong are the weaker alternate ones compared with the
    /// stronger ones? 1 = every pulse is an equal hit (a kick on every beat); low = every second
    /// one is just a hi-hat.
    private func pulseEvenness(_ x: [Float], lag: Double, n: Int) -> Float {
        let L = max(Int(lag.rounded()), 1)
        var bestPhase = 0
        var bestSum: Float = -1
        for phi in 0..<L {
            var sum: Float = 0, k = 0
            while true {
                let idx = n - 1 - phi - Int((Double(k) * lag).rounded())
                if idx < 0 || k > 16 { break }
                sum += x[idx]
                k += 1
            }
            if sum > bestSum { bestSum = sum; bestPhase = phi }
        }
        var even: Float = 0, odd: Float = 0, k = 0
        while true {
            let idx = n - 1 - bestPhase - Int((Double(k) * lag).rounded())
            if idx < 0 || k > 16 { break }
            if k % 2 == 0 { even += x[idx] } else { odd += x[idx] }
            k += 1
        }
        return min(even, odd) / max(max(even, odd), 1e-9)
    }

    private func estimate() {
        let n = filled
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n { x[i] = history[(head - n + i + capacity) % capacity] }

        // Remove the local average so only the spikes remain.
        let win = 24
        var smooth = [Float](repeating: 0, count: n)
        var acc: Float = 0
        for i in 0..<n {
            acc += x[i]
            if i >= win { acc -= x[i - win] }
            smooth[i] = acc / Float(min(i + 1, win))
        }
        for i in 0..<n { x[i] = max(0, x[i] - smooth[i]) }

        var energy: Float = 0
        vDSP_dotpr(x, 1, x, 1, &energy, vDSP_Length(n))
        guard energy > 1e-4 else { confidence *= 0.8; return }

        let minLag = Int(rate * 60 / 190 / Double(hop))
        let maxLag = Int(rate * 60 / 70 / Double(hop))
        let longest = min(maxLag * 2, n - 64)
        guard longest > maxLag else { return }
        var ac = [Float](repeating: 0, count: longest + 2)
        x.withUnsafeBufferPointer { p in
            for lag in minLag...(longest + 1) where lag < n {
                var d: Float = 0
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &d, vDSP_Length(n - lag))
                ac[lag] = d / Float(n)          // same divisor for every lag: longer lags aren't flattered
            }
        }

        var bestLag = minLag
        var bestScore: Float = -1
        var scores = [Float](repeating: 0, count: maxLag + 2)
        for lag in minLag...maxLag {
            let bpm = 60 * rate / Double(lag * hop)
            let prior = Float(exp(-0.5 * pow(log2(bpm / 120) / 0.55, 2)))
            var s = ac[lag]
            if lag * 2 <= longest { s += 0.5 * ac[lag * 2] }
            s *= 0.6 + 0.4 * prior
            scores[lag] = s
            if s > bestScore { bestScore = s; bestLag = lag }
        }

        var lag = Double(bestLag)
        // Stay on the current tempo if the new pick is just its double or half.
        if lastLag > 0 {
            for factor in [2.0, 0.5] where abs(Double(bestLag) / (lastLag * factor) - 1) < 0.06 {
                let candidate = Int((lastLag).rounded())
                if candidate >= minLag, candidate <= maxLag { bestLag = candidate; lag = Double(candidate) }
            }
        }
        // A 174 BPM track correlates just as well at 87 BPM, and correlation alone picks the slow
        // one. Half the gap is the real beat only when every one of those pulses is a proper hit —
        // hi-hats between the beats also correlate at half the gap, but they're much quieter.
        // Decided over several readings, so one noisy window can't switch the tempo on its own.
        let half = bestLag / 2
        let faster = half - 1 >= minLag
            ? (max(minLag, half - 1)...min(half + 1, maxLag)).max(by: { ac[$0] < ac[$1] })
            : nil
        var evenness: Float = 0
        if let faster, ac[faster] >= ac[bestLag] * 0.45 {
            evenness = pulseEvenness(x, lag: Double(faster), n: n)
        }
        // Dead band between the two thresholds: material that sits near the line doesn't drift
        // across by chance.
        let need = 3                                    // readings that must agree before switching
        if evenness >= 0.45 {
            octaveBias = min(octaveBias + 1, need + 2)
            unclear = 0
        } else if evenness <= 0.3 {
            octaveBias = max(octaveBias - 1, -2)
            unclear = 0
        } else {
            // Neither one thing nor the other: let the evidence fade rather than bank it, so
            // music that sits on the line can't creep over it.
            unclear += 1
            if unclear >= 6 {
                unclear = 0
                octaveBias -= octaveBias > 0 ? 1 : (octaveBias < 0 ? -1 : 0)
            }
        }
        if Self.debug, let faster {
            print(String(format: "   %.0f BPM (lag %d, ac %.3f) vs half %.0f BPM (lag %d, ac %.3f): evenness %.2f, bias %d",
                         60 * rate / Double(bestLag * hop), bestLag, ac[bestLag],
                         60 * rate / Double(faster * hop), faster, ac[faster], evenness, octaveBias))
        }
        if octaveBias >= need, let faster {
            bestLag = faster
            lag = Double(faster)
        }
        if bestLag > minLag, bestLag < maxLag {
            let a = scores[bestLag - 1], b = scores[bestLag], c = scores[bestLag + 1]
            let denom = a - 2 * b + c
            if abs(denom) > 1e-9 { lag += Double(0.5 * (a - c) / denom) }
        }

        let meanEnergy = energy / Float(n)
        let raw = min(max(ac[bestLag] / max(meanEnergy, 1e-6), 0), 1)
        if lastLag > 0, abs(lag - lastLag) / lastLag < 0.03 { stableCount += 1 } else { stableCount = 0 }
        lastLag = lag
        let target = raw * Float(min(Double(stableCount) / 3, 1))
        confidence += (target - confidence) * 0.35

        // Phase: comb over the last few beats, newest weighted most.
        let L = Int(lag.rounded())
        var bestPhase = 0
        var bestSum: Float = -1
        for phi in 0..<L {
            var sum: Float = 0
            var weight: Float = 1
            var k = 0
            while true {
                let idx = n - 1 - phi - Int((Double(k) * lag).rounded())
                if idx < 0 || k > 8 { break }
                sum += x[idx] * weight
                weight *= 0.85
                k += 1
            }
            if sum > bestSum { bestSum = sum; bestPhase = phi }
        }
        let measuredBeat = Double(newestEnd) - Double(bestPhase * hop) - onsetOffset
        let measuredPeriod = lag * Double(hop)

        if period == 0 || abs(measuredPeriod - period) / period > 0.06 {
            period = measuredPeriod
            anchor = measuredBeat
        } else {
            period += (measuredPeriod - period) * 0.2
            let k = ((measuredBeat - anchor) / period).rounded()
            let predicted = anchor + k * period
            let err = measuredBeat - predicted
            anchor = predicted + err * 0.35
        }
    }
}
