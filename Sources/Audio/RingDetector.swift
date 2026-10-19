import Foundation

/// What just started sounding, as a 16-band "fingerprint": how much each band (40 Hz – 16 kHz)
/// rose over the last ~85 ms. The same drum hit gives nearly the same fingerprint every time
/// it comes around, whatever else is playing.
final class OnsetFingerprint {
    static let bands = 16
    private(set) var current = [Float](repeating: 0, count: bands)
    private var edges: [Double] = (0...bands).map { 40 * pow(400, Double($0) / Double(bands)) }
    private var history = [Float](repeating: -120, count: 16 * bands)
    private var cursor = 0

    func update(big: UnsafeMutablePointer<Float>, bigHalf: Int, bigBinHz: Double,
                small: UnsafeMutablePointer<Float>, smallHalf: Int, smallBinHz: Double) {
        for b in 0..<Self.bands {
            let useBig = edges[b + 1] <= 250
            let mags = useBig ? big : small
            let half = useBig ? bigHalf : smallHalf
            let binHz = useBig ? bigBinHz : smallBinHz
            // Bands above this device's Nyquist (8/16 kHz devices reach into the top few) carry
            // nothing: leave them empty instead of counting the last bin several times over.
            guard half > 1, Int((edges[b] / binHz).rounded(.down)) <= half - 1 else {
                current[b] = 0
                history[cursor * Self.bands + b] = -120
                continue
            }
            let lo = max(Int((edges[b] / binHz).rounded(.down)), 1)
            let hi = min(max(Int((edges[b + 1] / binHz).rounded(.down)), lo), half - 1)
            var e: Float = 0
            for k in lo...hi { e += mags[k] * mags[k] }
            let db = 10 * log10(e + 1e-9)
            var floor = db
            for h in 0..<16 { floor = min(floor, history[h * Self.bands + b]) }
            history[cursor * Self.bands + b] = db
            current[b] = min(max(0, db - floor), 30)
        }
        cursor = (cursor + 1) % 16
    }

    /// The fingerprint scaled to unit length — its shape, whatever the volume (nil when too faint).
    static func shape(_ p: [Float], minimum: Float) -> [Float]? {
        var n: Float = 0
        for v in p { n += v * v }
        n = n.squareRoot()
        guard n > minimum else { return nil }
        return p.map { $0 / n }
    }

    /// 1 = the same shape, 0 = nothing in common.
    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        var d: Float = 0
        for i in 0..<min(a.count, b.count) { d += a[i] * b[i] }
        return d
    }
}

/// Watches one frequency band and decides when a ring should fire.
///
/// Loudness and sudden change are judged against this song's own range in that band (its quiet
/// moments → its loudest), so the same settings suit a ballad and a club track. For consistency,
/// every sound that fires a ring is remembered by its fingerprint: when that sound comes back —
/// the same kick or snare in the next bar — it fires again even if it's a little quieter, or
/// the song around it has changed.
final class RingDetector {
    var id: UUID
    var rule: RingSettings.Rule
    var minGap: Double = 0.12
    var louderIsStronger = true
    /// Tests: turn off "remember sounds that fired" to compare.
    static var memoryEnabled = true
    /// Tests: every candidate peak (time s, level, jump, rise dB, span dB, print max).
    static var debug: ((Double, Float, Float, Float, Float, Float) -> Void)?
    /// Tests: every ring this detector fires (time s, fired by memory).
    static var debugFire: ((Double, Bool, String) -> Void)?
    /// Share of the rise that must happen within about one analysis window: a real hit jumps
    /// at once, while two low notes beating against each other swell slowly.
    static let sharpness: Float = 0.75
    /// Tests: every candidate with the numbers behind the decision.
    static var debugCandidate: ((Double, String) -> Void)?

    /// Latest values for the settings meter (0…1 of the song's range).
    private(set) var level: Float = 0
    private(set) var jumpNow: Float = 0
    private(set) var remembered = 0

    private var recent = [Float](repeating: -120, count: 16)
    private var cursor = 0
    private var songLevels: [Float] = []
    private var decimate = 0
    private var sinceRefresh = 0
    private var quiet: Float = -60
    private var loud: Float = -20
    private var warmedUp = false
    private var previous = (level: Float(0), jump: Float(0), rise: Float(0), db: Float(-120), fast: Float(0))
    private var previousPrint = [Float](repeating: 0, count: OnsetFingerprint.bands)
    private var beforePrevious: Float = 0
    private var lastEvent = -1e12
    /// Rises of recent candidate peaks in this band (dB) — "sudden change" is judged against the big ones.
    private var peakRises: [Float] = []
    private var bigJump: Float = 10

    /// A sound that fired: its shape, how big it was, and where in the beat it has landed.
    private struct Memory {
        var shape: [Float]
        var rise: Float
        var db: Float
        var seen: Double
        var slotHits = [Int](repeating: 0, count: 16)
        /// Strong hits at this place in the beat (±1/16 of a beat).
        func hits(near slot: Int) -> Int { slotHits[slot] + slotHits[(slot + 1) % 16] + slotHits[(slot + 15) % 16] }
    }
    private var memories: [Memory] = []

    init(rule: RingSettings.Rule) {
        id = rule.id
        self.rule = rule
    }

    /// New song: the old song's loudness range and remembered drum sounds don't apply.
    func forgetSong() {
        memories.removeAll()
        songLevels.removeAll()
        peakRises.removeAll()
        warmedUp = false
        bigJump = 10
        lastEvent = -1e12
        remembered = 0
        level = 0
        jumpNow = 0
    }

    /// Call once per analysis step. Returns (sample, strength) when a ring should fire.
    func process(big: UnsafeMutablePointer<Float>, bigHalf: Int, bigBinHz: Double,
                 small: UnsafeMutablePointer<Float>, smallHalf: Int, smallBinHz: Double,
                 fingerprint: [Float], hopEnd: Int, hop: Int, rate: Double, gate: Bool,
                 beatSlot: (Double) -> Int?) -> (sample: Double, strength: Float)? {
        let band = rule.range
        let useBig = band.lowerBound < 250
        let mags = useBig ? big : small
        let half = useBig ? bigHalf : smallHalf
        let binHz = useBig ? bigBinHz : smallBinHz
        var lo = max(Int((band.lowerBound / binHz).rounded(.up)), 1)
        var hi = min(Int((min(band.upperBound, rate * 0.49) / binHz).rounded(.down)), half - 1)
        if hi < lo { lo = min(max(Int((band.lowerBound / binHz).rounded()), 1), half - 1); hi = lo }
        var energy: Float = 0
        for k in lo...hi { energy += mags[k] * mags[k] }
        let db = 10 * log10(energy + 1e-9)

        recent[cursor] = db
        cursor = (cursor + 1) % recent.count
        let rise = max(0, db - (recent.min() ?? db))
        // The same rise measured over roughly one FFT window (8 steps for the long one, 4 for the short one).
        var fastFloor = db
        for k in 1...(useBig ? 8 : 4) { fastFloor = min(fastFloor, recent[(cursor - 1 - k + recent.count * 2) % recent.count]) }
        let fast = max(0, db - fastFloor)

        // This song's range in the band, eased so thresholds don't wander bar to bar.
        decimate += 1
        if decimate >= 8, gate {
            decimate = 0
            songLevels.append(db)
            if songLevels.count > 900 { songLevels.removeFirst(songLevels.count - 900) }
            sinceRefresh += 1
            if sinceRefresh >= 12 || (!warmedUp && songLevels.count >= 24) {
                sinceRefresh = 0
                let sorted = songLevels.sorted()
                let q = sorted[Int(Double(sorted.count - 1) * 0.1)]
                let l = sorted[Int(Double(sorted.count - 1) * 0.98)]
                if warmedUp {
                    quiet += (q - quiet) * 0.15
                    loud += (l - loud) * 0.15
                } else {
                    quiet = q
                    loud = l
                    warmedUp = songLevels.count >= 24
                }
            }
        }
        let span = max(loud - quiet, 12)
        let levelNow = gate ? min(max((db - quiet) / span, 0), 1) : 0
        let jump = gate ? min(rise / bigJump, 1) : 0
        level = levelNow
        jumpNow = jump

        defer {
            beforePrevious = previous.rise
            previous = (levelNow, jump, rise, db, fast)
            previousPrint = fingerprint
        }

        let now = Double(hopEnd) / rate
        memories.removeAll { now - $0.seen > 45 }
        remembered = memories.count

        // Candidate: the step where the rise peaked (confirmed one step later).
        let offset = useBig ? 1370.0 : 530.0
        let sample = Double(hopEnd - hop) - offset
        guard gate, previous.rise > 1.5, previous.rise >= beforePrevious, previous.rise > rise else { return nil }
        let sharp = previous.fast >= previous.rise * Self.sharpness
        peakRises.append(previous.rise)
        if peakRises.count > 96 { peakRises.removeFirst(peakRises.count - 96) }
        if peakRises.count >= 8 {
            let sorted = peakRises.sorted()
            let target = max(sorted[Int(Double(sorted.count - 1) * 0.9)], 6)
            bigJump += (target - bigJump) * (warmedUp ? 0.1 : 0.5)
        }
        guard warmedUp, sharp, sample - lastEvent >= minGap * rate else { return nil }

        let needLevel = Float(rule.loudness), needJump = Float(rule.jump)
        var strength: Float = 1
        Self.debug?(sample / rate, previous.level, previous.jump, previous.rise, span, previousPrint.max() ?? 0)

        let slot = beatSlot(sample)
        if let debug = Self.debugCandidate {
            var best = "no memory"
            if let slot, let shape = OnsetFingerprint.shape(previousPrint, minimum: 0) {
                let scored = memories.map { m in (m, OnsetFingerprint.similarity(shape, m.shape)) }.max { $0.1 < $1.1 }
                if let (m, sim) = scored {
                    best = String(format: "sim %.2f hits %d rise %.0f%% db %+.1f norm %.1f", sim, m.hits(near: slot), previous.rise / max(m.rise, 1) * 100,
                                  previous.db - m.db, previousPrint.reduce(0) { $0 + $1 * $1 }.squareRoot())
                }
            }
            debug(sample / rate, String(format: "%@ slot %@ level %.2f/%.2f jump %.2f/%.2f rise %.1f fast %.1f · %@", rule.source.rawValue,
                                        slot.map { "\($0)" } ?? "-", previous.level, needLevel, previous.jump, needJump, previous.rise, previous.fast, best))
        }
        // Loud and sudden enough — or among the loudest moments in this range and fairly sudden.
        if previous.level >= needLevel, previous.jump >= needJump
            || (previous.level >= max(needLevel, 0.85) && previous.jump >= needJump * 0.6) {
            remember(now: now, slot: slot)
            if louderIsStronger {
                let overLevel = (previous.level - needLevel) / max(1.0001 - needLevel, 0.05)
                let overJump = (previous.jump - needJump) / max(1.0001 - needJump, 0.05)
                strength = 0.5 + 0.5 * min(max(max(overLevel, overJump), 0), 1)
            }
            Self.debugFire?(sample / rate, false, rule.source.rawValue)
        } else if Self.memoryEnabled, previous.level >= needLevel - 0.45, let slot, let i = matchingMemory(slot: slot) {
            // A sound that has already fired several times at this place in the beat is back:
            // fire again, even if it's softer this time.
            memories[i].seen = now
            if louderIsStronger { strength = min(1, 0.45 + 0.55 * previous.rise / max(memories[i].rise, 1)) }
            Self.debugFire?(sample / rate, true, rule.source.rawValue)
        } else {
            return nil
        }
        lastEvent = sample
        return (sample, strength)
    }

    /// A remembered sound with the same shape that has repeated at this place in the beat.
    private func matchingMemory(slot: Int) -> Int? {
        guard let shape = OnsetFingerprint.shape(previousPrint, minimum: 4) else { return nil }
        var best: (index: Int, similarity: Float)?
        for (i, m) in memories.enumerated()
        where m.hits(near: slot) >= Self.repeatsNeeded && previous.rise >= max(2.5, m.rise * 0.2) && previous.db >= m.db - 16 {
            let s = OnsetFingerprint.similarity(shape, m.shape)
            if s >= 0.8, s > (best?.similarity ?? 0) { best = (i, s) }
        }
        return best?.index
    }

    /// Strong hits at the same place in the beat before softer repeats fire too.
    static var repeatsNeeded = 3

    private func remember(now: Double, slot: Int?) {
        guard let shape = OnsetFingerprint.shape(previousPrint, minimum: 6) else { return }
        let nearest = memories.indices.max { OnsetFingerprint.similarity(shape, memories[$0].shape) < OnsetFingerprint.similarity(shape, memories[$1].shape) }
        if let i = nearest, OnsetFingerprint.similarity(shape, memories[i].shape) >= 0.9 {
            var merged = memories[i].shape
            for b in merged.indices { merged[b] += (shape[b] - merged[b]) * 0.25 }
            memories[i].shape = OnsetFingerprint.shape(merged, minimum: 0) ?? memories[i].shape
            memories[i].rise += (previous.rise - memories[i].rise) * 0.25
            memories[i].db += (previous.db - memories[i].db) * 0.25
            memories[i].seen = now
            if let slot { memories[i].slotHits[slot] += 1 }
            return
        }
        if memories.count >= 8, let oldest = memories.indices.min(by: { memories[$0].seen < memories[$1].seen }) {
            memories.remove(at: oldest)
        }
        var m = Memory(shape: shape, rise: previous.rise, db: previous.db, seen: now)
        if let slot { m.slotHits[slot] = 1 }
        memories.append(m)
    }
}
