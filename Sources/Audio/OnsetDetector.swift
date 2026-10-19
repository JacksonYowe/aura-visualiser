import Foundation

/// Adaptive peak-picker for one onset-strength stream (e.g. kick or snare/hat flux).
struct PeakPicker {
    var sensitivity: Float          // std-devs above the running mean
    var floor: Float                // ignore peaks below this absolute value
    var minGapSamples: Double

    private var mean: Float = 0
    private var variance: Float = 0
    private var v2: Float = 0       // two hops ago
    private var v1: Float = 0       // one hop ago (candidate)
    private var lastOnset = -Double.greatestFiniteMagnitude
    /// Recent loudest peak; candidates must reach a share of it (stops swells passing as hits).
    private var peakLevel: Float = 0
    var relativeFloor: Float = 0.3

    init(sensitivity: Float, floor: Float, minGapSamples: Double) {
        self.sensitivity = sensitivity
        self.floor = floor
        self.minGapSamples = minGapSamples
    }

    /// Feed the newest value. Returns (strength) when the *previous* hop was a peak.
    mutating func push(_ v0: Float, candidateSample: Double, alpha: Float, gate: Bool) -> Float? {
        defer {
            let dev = v1 - mean
            mean += dev * alpha
            variance += (dev * dev - variance) * alpha
            v2 = v1
            v1 = v0
        }
        peakLevel = max(v0, peakLevel * (1 - alpha * 0.5))
        guard gate else { return nil }
        let std = sqrt(max(variance, 1e-6))
        let threshold = max(mean + sensitivity * std, relativeFloor * peakLevel)
        guard v1 > threshold, v1 > floor, v1 >= v2, v1 > v0,
              candidateSample - lastOnset > minGapSamples else { return nil }
        lastOnset = candidateSample
        return min(max((v1 - mean) / (3.5 * std + 1e-4), 0.45), 1)
    }

    mutating func reset() {
        let rel = relativeFloor
        self = PeakPicker(sensitivity: sensitivity, floor: floor, minGapSamples: minGapSamples)
        relativeFloor = rel
    }
}
