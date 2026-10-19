import Accelerate
import Foundation

/// Turns raw samples into everything the shaders need: a 64-band spectrum, bass / mid /
/// treble levels, beat + hit pulses, tempo phase, loudness and an oscilloscope trace.
///
/// Timing model: every frame is rendered for the moment it will appear on screen. The ring
/// buffer's stamp says when each sample reaches your ears, so the analyser looks at exactly
/// the audio you'll be hearing then. Beats are detected in audio that hasn't been heard yet
/// and fired on their precise sample; when there isn't enough look-ahead, the tempo tracker
/// predicts them instead.
final class AudioAnalyzer {
    static let bandCount = 64
    static let waveCount = 512

    struct Features {
        var bass: Float = 0, mid: Float = 0, treble: Float = 0, energy: Float = 0
        var beat: Float = 0          // kick / strong onset pulse
        var hit: Float = 0           // snare / hat pulse
        var beatCount = 0
        var flow: Float = 0
        var silent = true
        var beatPhase: Float = 0
        var tempoLock: Float = 0
        var bpm: Double = 0
        var lookAhead: Double = 0    // seconds of audio known beyond the displayed moment
        var ringsLaunched = 0
        var kickOnBeat: Float = 0     // how often a grid beat has a kick (four-on-the-floor → 1)
        var lowShare: Float = 0       // share of the spectrum below ~150 Hz
    }

    private(set) var features = Features()
    private(set) var bands = [Float](repeating: 0, count: bandCount)
    private(set) var peaks = [Float](repeating: 0, count: bandCount)
    private(set) var wave = [Float](repeating: 0, count: waveCount)

    var sensitivity: Float = 1
    /// Seconds; positive delays the visuals.
    var syncOffset: Double = 0
    /// How far ahead of the sound the visuals aim (perception favours light slightly first).
    var visualLead: Double = 0.012
    /// Test hooks: (onset sample, strength, isLow) when detected; (sample, predicted) when a beat fires.
    var onDetect: ((Double, Float, Bool) -> Void)?
    var onFire: ((Double, Bool) -> Void)?
    var onHop: ((Int, Float, Float) -> Void)?

    private let big = SpectrumFFT(log2n: 12)
    private let small = SpectrumFFT(log2n: 10)
    private let bigBuf = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    private let smallBuf = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    private let hopBuf = UnsafeMutablePointer<Float>.allocate(capacity: 2048)
    private let kickFFT = SpectrumFFT(log2n: 11)

    private var rate: Double = 0
    private var bandLo = [Double](repeating: 0, count: bandCount)
    private var bandHi = [Double](repeating: 0, count: bandCount)
    private var bandCenter = [Double](repeating: 0, count: bandCount)

    // Clock
    private var visual: Double = 0
    private var visualValid = false
    private var previousVisual: Double = 0

    // Onsets
    static let hop = 256
    /// Samples between an onset and the end of the hop whose flux peaks for it (calibrated with
    /// --latency-test): kick band uses a 2048 window, snare/hat band a 1024 window.
    static let lowOffset: Double = 440
    static let highOffset: Double = 400
    static let onsetOffset: Double = lowOffset
    private var analyzedUpTo = 0
    private var prevLog = [Float](repeating: 0, count: 200)
    private var prevLowLog: Float = 0
    private var lowPicker: PeakPicker = {
        var p = PeakPicker(sensitivity: 1.5, floor: 0.4, minGapSamples: 0)
        p.relativeFloor = 0.5
        return p
    }()
    private var highPicker = PeakPicker(sensitivity: 1.8, floor: 0.35, minGapSamples: 0)
    private var pendingLow: [(sample: Double, strength: Float)] = []
    private var pendingHigh: [(sample: Double, strength: Float)] = []
    private var pendingVoice: [(sample: Double, strength: Float)] = []
    private var lastVoice = (sample: -1e12, strength: Float(0))
    /// Moments singing started (after a break) that reached the listener this frame.
    private(set) var voiceOnsetsThisFrame: [(sample: Double, strength: Float)] = []
    /// Recent (sample, singing 0…1) pairs, oldest first, for looking up the heard moment.
    private var activityTrail: [(sample: Double, value: Float)] = []
    private var singing = false
    private var quietSince = 0.0
    /// The sample being heard when the current frame is shown.
    private(set) var visualSample: Double = 0
    private var lastBeat = (sample: -1e12, strength: Float(0))
    private var lastHit = (sample: -1e12, strength: Float(0))
    private var lastPredicted = -1e12
    private var tracker: BeatTracker?

    // Levels
    private var reference: Float = -30
    private var silentTime: Double = 10
    private struct Dyn { var avg: Float = 0; var peak: Float = 0.2; var out: Float = 0 }
    private var bassDyn = Dyn(), midDyn = Dyn(), trebleDyn = Dyn()
    private var wavePeak: Float = 0.05
    private var smooth = [Float](repeating: 0, count: 2048)

    init() {
        bigBuf.initialize(repeating: 0, count: 4096)
        smallBuf.initialize(repeating: 0, count: 4096)
        hopBuf.initialize(repeating: 0, count: 2048)
        rebuildDetectors()
    }

    deinit { bigBuf.deallocate(); smallBuf.deallocate(); hopBuf.deallocate(); sideBuf.deallocate() }

    private func configure(sampleRate: Double) {
        rate = sampleRate
        let fMin = 30.0, fMax = min(16_000.0, sampleRate * 0.45), ratio = fMax / fMin
        for b in 0..<Self.bandCount {
            bandLo[b] = fMin * pow(ratio, Double(b) / Double(Self.bandCount))
            bandHi[b] = fMin * pow(ratio, Double(b + 1) / Double(Self.bandCount))
            bandCenter[b] = sqrt(bandLo[b] * bandHi[b])
        }
        tracker = BeatTracker(hop: Self.hop, rate: sampleRate, onsetOffset: Self.onsetOffset)
        visualValid = false
    }

    /// Call once per frame with the time the frame will be on screen (CACurrentMediaTime seconds).
    func update(presentTime: Double, dt rawDT: Double, ring: SampleRingBuffer, side: SampleRingBuffer? = nil,
                sampleRate: Double) {
        let dt = min(max(rawDT, 1.0 / 240), 0.1)
        if sampleRate != rate { configure(sampleRate: sampleRate) }
        let newest = ring.totalWritten

        // --- Which sample will be heard when this frame appears?
        var target = Double(newest) - 0.03 * rate
        if let stamp = ring.stamp() {
            target = Double(stamp.count) + (presentTime + visualLead - syncOffset - stamp.heardAt) * rate
        }
        if !visualValid || abs(target - visual) > 0.06 * rate {
            visual = target
            visualValid = true
            previousVisual = target
        } else {
            visual += dt * rate
            visual += (target - visual) * min(1, dt * 10)
        }
        let v = visual

        analyseOnsets(ring: ring, side: side, newest: newest)
        let horizon = Double(analyzedUpTo) - Self.onsetOffset - Double(Self.hop)
        features.lookAhead = (horizon - v) / rate

        fireBeats(at: v)
        analyseSpectrum(ring: ring, center: v, newest: newest, dt: Float(dt))
        buildWave(ring: ring, center: v, newest: newest, dt: Float(dt))

        if let tracker {
            features.tempoLock += ((tracker.locked ? 1 : 0) - features.tempoLock) * Float(min(1, dt * 3))
            features.beatPhase = Float(tracker.phase(at: v))
            features.bpm = tracker.bpm
        }
        features.flow += Float(dt) * (0.22 + 1.25 * features.energy + 0.55 * features.beat)
        if features.flow > 16384 { features.flow -= 16384 }      // Float32 keeps its step size
        previousVisual = v
    }

    // MARK: Onsets (streaming, hop by hop)

    let vocal = VocalActivityDetector()
    private let sideFFT = SpectrumFFT(log2n: 10)
    private let sideBuf: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
        p.initialize(repeating: 0, count: 1024)
        return p
    }()
    /// Seconds before being heard that a phrase start is handed to the lyrics (if already analysed).
    var voiceLead: Double = 0

    /// Samples between singing starting and the detector reporting it (calibrated with --voice-test).
    static var voiceOffset: Double = 1500

    /// Most singing (0…1) anywhere between two samples — reaches into audio not heard yet.
    func vocalActivityMax(from a: Double, to b: Double) -> Float {
        var best: Float = 0
        for entry in activityTrail.reversed() {
            if entry.sample < a { break }
            if entry.sample <= b { best = max(best, entry.value) }
        }
        return best
    }

    /// How much singing (0…1) is in the audio at `sample`.
    func vocalActivity(atSample sample: Double) -> Float {
        guard let last = activityTrail.last else { return 0 }
        if sample >= last.sample { return last.value }
        var lo = 0, hi = activityTrail.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if activityTrail[mid].sample <= sample { lo = mid } else { hi = mid - 1 }
        }
        return activityTrail[lo].value
    }

    private func analyseOnsets(ring: SampleRingBuffer, side: SampleRingBuffer?, newest: Int) {
        let hop = Self.hop
        if newest - analyzedUpTo > Int(rate) || analyzedUpTo > newest {
            analyzedUpTo = max(0, newest - hop * 8)       // skip a backlog (window was hidden)
            lowPicker.reset(); highPicker.reset(); vocal.reset()
            activityTrail.removeAll(); singing = false
        }
        let alpha = Float(1 - exp(-Double(hop) / rate / 1.0))
        while analyzedUpTo + hop <= newest {
            let end = analyzedUpTo + hop
            analyzedUpTo = end
            ring.read(into: hopBuf, count: 2048, endingAt: end)
            var rms: Float = 0
            vDSP_rmsqv(hopBuf + 1024, 1, &rms, 1024)

            // Kick: total energy below ~140 Hz as one band, from a 2048 window. Shorter windows
            // let a low note's ± frequency images beat against each other at twice its pitch.
            kickFFT.process(hopBuf)
            var lowPower: Float = 0
            for k in 1...6 { lowPower += kickFFT.magnitudes[k] * kickFFT.magnitudes[k] }
            let lowLog = log(1 + 400 * lowPower)
            let low = max(0, lowLog - prevLowLog) * 2.5
            prevLowLog = lowLog

            small.process(hopBuf + 1024)
            let m = small.magnitudes
            var high: Float = 0
            for k in 6..<200 {
                let l = log(1 + 300 * m[k])
                let d = l - prevLog[k]
                prevLog[k] = l
                if d > 0 { high += d }
            }
            high /= 14
            var sideMags: UnsafeMutablePointer<Float>?
            if let side {
                side.read(into: sideBuf, count: 1024, endingAt: end)
                sideFFT.process(sideBuf)
                sideMags = sideFFT.magnitudes
            }
            let singingNow = vocal.process(mid: m, side: sideMags, loud: rms > 0.002)
            onHop?(end, low, high)
            let gate = rms > 0.002
            if !ringDetectors.isEmpty {
                let bigHz = rate / Double(kickFFT.n), smallHz = rate / Double(small.n)
                fingerprint.update(big: kickFFT.magnitudes, bigHalf: kickFFT.half, bigBinHz: bigHz,
                                   small: m, smallHalf: small.half, smallBinHz: smallHz)
                for detector in ringDetectors {
                    if let hit = detector.process(big: kickFFT.magnitudes, bigHalf: kickFFT.half, bigBinHz: bigHz,
                                                  small: m, smallHalf: small.half, smallBinHz: smallHz,
                                                  fingerprint: fingerprint.current, hopEnd: end, hop: hop, rate: rate, gate: gate,
                                                  beatSlot: beatSlot) {
                        pendingLoudHits.append(hit)
                    }
                }
                if pendingLoudHits.count > 64 { pendingLoudHits.removeFirst(pendingLoudHits.count - 64) }
            }
            let lowCandidate = Double(end - hop) - Self.lowOffset
            let highCandidate = Double(end - hop) - Self.highOffset
            if let s = lowPicker.push(low, candidateSample: lowCandidate, alpha: alpha, gate: gate) {
                recentLowOnsets.append((lowCandidate, s))
                if recentLowOnsets.count > 32 { recentLowOnsets.removeFirst() }
                Self.merge(&pendingLow, (lowCandidate, s), gap: 0.1 * rate, fired: lastBeat)
                onDetect?(lowCandidate, s, true)
            }
            if let s = highPicker.push(high, candidateSample: highCandidate, alpha: alpha, gate: gate) {
                Self.merge(&pendingHigh, (highCandidate, s), gap: 0.07 * rate, fired: lastHit)
                onDetect?(highCandidate, s, false)
            }
            // Singing on/off with hysteresis; a start after ≥0.25 s of quiet is a phrase start.
            let at = Double(end) - Self.voiceOffset
            activityTrail.append((at, singingNow))
            if activityTrail.count > 600 { activityTrail.removeFirst(activityTrail.count - 600) }
            if singing {
                if singingNow < 0.35 { singing = false; quietSince = at }
            } else if singingNow > 0.6 {
                singing = true
                if at - quietSince > 0.25 * rate {
                    pendingVoice.append((at, 1))
                    if pendingVoice.count > 32 { pendingVoice.removeFirst() }
                }
            }
            tracker?.push(gate ? low * 1.5 + high * 0.5 : 0, hopEnd: end)
            if let tracker, tracker.locked {
                lockedPeriod = tracker.period
                lastLockSample = Double(end)
            }
        }
    }

    /// Adds an onset unless one within `gap` is already queued or fired; a stronger newcomer
    /// replaces a weaker queued one (so a small wobble can't swallow the real kick after it).
    private static func merge(_ queue: inout [(sample: Double, strength: Float)], _ onset: (Double, Float),
                              gap: Double, fired: (sample: Double, strength: Float)) {
        // Too close to one already shown — unless it's clearly the real hit.
        if onset.0 - fired.sample < gap, onset.1 < fired.strength * 1.4 { return }
        if let last = queue.last, onset.0 - last.sample < gap {
            if onset.1 > last.strength { queue[queue.count - 1] = (onset.0, onset.1) }
            return
        }
        queue.append((onset.0, onset.1))
        if queue.count > 64 { queue.removeFirst() }
    }

    private func fireBeats(at v: Double) {
        visualSample = v
        ringEventsThisFrame.removeAll(keepingCapacity: true)
        pendingLoudHits.sort { $0.sample < $1.sample }
        let grid = gridUsable(at: v)
        while let first = pendingLoudHits.first, first.sample <= v {
            pendingLoudHits.removeFirst()
            guard !features.silent, v - first.sample < 0.3 * rate else { continue }
            if let every = triggers.beatsPerRing {
                // Tempo-locked rings come from the grid; triggers only stand in while there's no tempo.
                let beat = lockedPeriod > 0 ? lockedPeriod : 0.5 * rate
                guard !grid, first.sample - lastRingSample >= Double(every) * beat * 0.9 else { continue }
            }
            addRing(first.sample, first.strength)
        }
        if triggers.beatsPerRing != nil, grid { ringsOnGrid(at: v) }
        while let first = pendingHigh.first, first.sample <= v {
            pendingHigh.removeFirst()
            lastHit = (first.sample, first.strength)
        }
        voiceOnsetsThisFrame.removeAll(keepingCapacity: true)
        while let first = pendingVoice.first, first.sample <= v + voiceLead * rate {
            pendingVoice.removeFirst()
            lastVoice = (first.sample, first.strength)
            if v - first.sample < 0.4 * rate { voiceOnsetsThisFrame.append(first) }
        }

        if let tracker, tracker.locked {
            fireOnGrid(tracker, at: v)
        } else {
            while let first = pendingLow.first, first.sample <= v {
                pendingLow.removeFirst()
                fire(first.sample, first.strength, predicted: false)
            }
        }

        let beatAge = max(0, v - lastBeat.sample) / rate
        let hitAge = max(0, v - lastHit.sample) / rate
        features.beat = features.silent ? 0 : lastBeat.strength * Float(exp(-beatAge / 0.12))
        features.hit = features.silent ? 0 : lastHit.strength * Float(exp(-hitAge / 0.08))
    }

    private var lastGrid = -1e12
    private var gridHitRate: Float = 1

    /// Tempo locked: one flash per grid beat, placed on the detected kick when there is one nearby.
    /// Stray detections between beats are ignored unless they're very strong.
    private func fireOnGrid(_ tracker: BeatTracker, at v: Double) {
        let window = 0.045 * rate
        // Grid beats that have come due since the last frame.
        var guardCount = 0
        while let g = tracker.nextBeat(after: max(lastGrid + 0.5 * tracker.period, previousVisual - 0.2 * rate)),
              g - window <= v, guardCount < 4 {
            guardCount += 1
            if let i = pendingLow.firstIndex(where: { abs($0.sample - g) < window }) {
                let onset = pendingLow.remove(at: i)
                guard onset.sample <= v else {                  // detected kick is still ahead: wait for it
                    pendingLow.insert(onset, at: i)
                    break
                }
                lastGrid = g
                gridHitRate += (1 - gridHitRate) * 0.25
                features.kickOnBeat += (1 - features.kickOnBeat) * 0.08
                fire(onset.sample, onset.strength, predicted: false)
            } else if g <= v {
                let sure = features.lookAhead > 0.05              // we've already analysed past this beat
                lastGrid = g
                if sure {
                    gridHitRate += (0 - gridHitRate) * 0.25
                    features.kickOnBeat += (0 - features.kickOnBeat) * 0.08
                }
                if !sure || gridHitRate > 0.5 {
                    fire(g, sure ? 0.6 : 0.85, predicted: true)
                }
            } else {
                break
            }
        }
        // Off-grid detections: only strong accents get through.
        while let first = pendingLow.first, first.sample <= v, abs(first.sample - (lastGrid)) > window {
            pendingLow.removeFirst()
            if first.strength >= 0.95, first.sample - lastBeat.sample > 0.1 * rate {
                fire(first.sample, first.strength * 0.8, predicted: false)
            }
        }
        // Anything left that already fell behind the grid beat is stale.
        pendingLow.removeAll { $0.sample < v - window }
    }

    private func fire(_ sample: Double, _ strength: Float, predicted: Bool) {
        if predicted { lastPredicted = sample }
        else if abs(sample - lastPredicted) < 0.07 * rate { return }   // prediction already shown
        lastBeat = (sample, strength)
        features.beatCount += 1
        if triggers.beatsPerRing == nil, triggers.alsoOnBeats || triggers.rules.isEmpty {
            onRingSource?(sample, "beat")
            addRing(sample, ringSettings.louderIsStronger ? max(strength, 0.6) : 1)
        }
        onFire?(sample, predicted)
    }

    // MARK: Ring pulses

    /// Pulses that reached the screen this frame: every beat plus every sudden, very loud hit.
    private(set) var ringEventsThisFrame: [(sample: Double, strength: Float)] = []
    private var pendingLoudHits: [(sample: Double, strength: Float)] = []
    /// One detector per active trigger (rebuilt when settings or the detected genre change,
    /// keeping the memory of detectors whose trigger is unchanged).
    private(set) var ringDetectors: [RingDetector] = []
    private let fingerprint = OnsetFingerprint()
    private(set) var triggers = RingSettings().triggers(detected: nil)
    var ringSettings = RingSettings() { didSet { rebuildDetectors() } }
    var detectedGenre: RingSettings.Genre? { didSet { if detectedGenre != oldValue { rebuildDetectors() } } }

    /// New song: forget the last one's drum sounds, tempo and learned ranges.
    func trackChanged() {
        for detector in ringDetectors { detector.forgetSong() }
        vocal.reset()
        tracker?.reset()
        recentLowOnsets.removeAll()
        ringGridLast = -1e12
        ringBeatNumber = 0
        beatAccents = [Float](repeating: 0, count: 4)
        barStart = 0
        halfStart = 0
        lockedPeriod = 0
        lastLockSample = -1e12
    }

    /// Position in the beat (16 slots) of a sample. Keeps working through a quieter stretch where
    /// the tempo lock wavers, as long as the tempo hasn't changed since it was last locked.
    private func beatSlot(_ sample: Double) -> Int? {
        guard let tracker, tracker.period > 0, lockedPeriod > 0 else { return nil }
        if !tracker.locked {
            guard sample - lastLockSample < 15 * rate, abs(tracker.period / lockedPeriod - 1) < 0.03 else { return nil }
        }
        return Int((tracker.phase(at: sample) * 16).rounded()) % 16
    }
    private var lockedPeriod: Double = 0
    private var lastLockSample = -1e12

    /// The tempo grid can be trusted: locked, or only briefly wavering at the same tempo.
    private func gridUsable(at sample: Double) -> Bool {
        guard let tracker, tracker.period > 0, lockedPeriod > 0 else { return false }
        return tracker.locked || (sample - lastLockSample < 15 * rate && abs(tracker.period / lockedPeriod - 1) < 0.03)
    }

    // "Every beat / 2 beats / bar": rings on the tempo grid.
    private var recentLowOnsets: [(sample: Double, strength: Float)] = []
    private var ringGridLast = -1e12
    private var ringBeatNumber = 0
    /// How strongly each beat of the bar (by beat number mod 4) tends to hit — the bar starts on the strongest.
    private var beatAccents = [Float](repeating: 0, count: 4)
    private var barStart = 0
    private var halfStart = 0

    private func ringsOnGrid(at v: Double) {
        guard let tracker, let every = triggers.beatsPerRing, let period = Optional(tracker.period), period > 0 else { return }
        var guardCount = 0
        while guardCount < 8, let g = tracker.gridBeat(after: max(ringGridLast + 0.5 * period, v - 0.25 * rate)), g <= v {
            guardCount += 1
            ringBeatNumber += ringGridLast < 0 ? 1 : max(1, Int(((g - ringGridLast) / period).rounded()))
            ringGridLast = g
            let onset = recentLowOnsets.filter { abs($0.sample - g) < 0.06 * rate }.max { $0.strength < $1.strength }
            let slot = ringBeatNumber % 4
            beatAccents[slot] += ((onset?.strength ?? 0) - beatAccents[slot]) * 0.15

            // Which beat starts the bar (and which half of it), changing only on clear evidence
            // so the choice doesn't flip between equally strong beats.
            func score(_ start: Int, _ step: Int) -> Float {
                stride(from: 0, to: 4, by: step).reduce(0) { $0 + beatAccents[(start + $1) % 4] }
            }
            if let best = (0..<4).max(by: { score($0, 4) < score($1, 4) }), score(best, 4) > score(barStart, 4) * 1.3 + 0.05 {
                barStart = best
            }
            if let best = (0..<2).max(by: { score($0, 2) < score($1, 2) }), score(best, 2) > score(halfStart, 2) * 1.3 + 0.05 {
                halfStart = best
            }
            let start = every == 4 ? barStart : every == 2 ? halfStart : 0
            guard !features.silent, ((ringBeatNumber - start) % every + every) % every == 0 else { continue }
            let strength = ringSettings.louderIsStronger ? max(0.6, min(onset?.strength ?? 0.6, 1)) : 1
            addRing(g, strength)
        }
    }

    private func rebuildDetectors() {
        triggers = ringSettings.triggers(detected: detectedGenre)
        var reused = Set<ObjectIdentifier>()
        ringDetectors = triggers.rules.map { rule in
            if let existing = ringDetectors.first(where: { $0.rule.range == rule.range && !reused.contains(ObjectIdentifier($0)) }) {
                reused.insert(ObjectIdentifier(existing))
                existing.id = rule.id
                existing.rule = rule
                existing.minGap = triggers.minGap
                existing.louderIsStronger = ringSettings.louderIsStronger
                return existing
            }
            let d = RingDetector(rule: rule)
            d.minGap = triggers.minGap
            d.louderIsStronger = ringSettings.louderIsStronger
            return d
        }
    }
    private var lastRingSample = -1e12
    private var loudAverage: Float = -60
    private var loudPeak: Float = -60
    private var lastLoudHit = -1e12
    /// Test hook: (sample, strength) whenever a ring pulse is launched.
    var onRing: ((Double, Float) -> Void)?
    /// Test hook: which path launched a ring ("beat" or a trigger's source name).
    var onRingSource: ((Double, String) -> Void)?

    private func addRing(_ sample: Double, _ strength: Float) {
        // A kick is usually both a beat and a loud hit: one ring, the stronger of the two.
        if sample - lastRingSample < max(0.06, triggers.minGap) * rate {
            if let i = ringEventsThisFrame.indices.last, strength > ringEventsThisFrame[i].strength {
                ringEventsThisFrame[i].strength = strength
            }
            return
        }
        lastRingSample = sample
        features.ringsLaunched += 1
        ringEventsThisFrame.append((sample, min(strength, 1)))
        onRing?(sample, strength)
    }

    // MARK: Spectrum

    private func bandPower(_ mags: UnsafeMutablePointer<Float>, half: Int, binHz: Double, _ b: Int) -> Double {
        let lo = bandLo[b] / binHz, hi = bandHi[b] / binHz
        if hi - lo < 1 {
            let c = (lo + hi) * 0.5, i = Int(c), f = c - Double(i)
            let a = Double(mags[min(i, half - 1)]), z = Double(mags[min(i + 1, half - 1)])
            let mm = a + (z - a) * f
            return mm * mm * (hi - lo)
        }
        var power = 0.0
        var k = Int(lo.rounded(.up))
        let last = min(Int(hi), half - 1)
        while k <= last { let mm = Double(mags[k]); power += mm * mm; k += 1 }
        return power
    }

    private func analyseSpectrum(ring: SampleRingBuffer, center: Double, newest: Int, dt: Float) {
        let c = Int(center)
        ring.read(into: bigBuf, count: 4096, endingAt: min(c + 2048, newest))
        ring.read(into: smallBuf, count: 1024, endingAt: min(c + 512, newest))

        var rms: Float = 0
        vDSP_rmsqv(smallBuf, 1, &rms, 1024)
        silentTime = rms < 0.0003 ? silentTime + Double(dt) : 0
        features.silent = silentTime > 1.2

        big.process(bigBuf)
        small.process(smallBuf)
        let bigHz = rate / Double(big.n), smallHz = rate / Double(small.n)

        var db = [Float](repeating: -120, count: Self.bandCount)
        var frameMax: Float = -120
        for b in 0..<Self.bandCount {
            let f = bandCenter[b]
            let t = min(max((f - 250) / 150, 0), 1)       // 250–400 Hz crossover
            var power = 0.0
            if t < 1 { power += (1 - t) * bandPower(big.magnitudes, half: big.half, binHz: bigHz, b) }
            if t > 0 { power += t * bandPower(small.magnitudes, half: small.half, binHz: smallHz, b) }
            db[b] = Float(10 * log10(power + 1e-12) + 2.2 * log2(f / 1000))
            frameMax = max(frameMax, db[b])
        }

        if features.silent { reference = max(reference - dt * 3, -38) }
        else { reference = max(max(frameMax, reference - dt * 5), -58) }

        let range: Float = 36 / min(max(sensitivity, 0.5), 2)
        let release = 1 - exp(-dt / 0.1)
        var bass: Float = 0, mid: Float = 0, treble: Float = 0, all: Float = 0
        var nb: Float = 0, nm: Float = 0, nt: Float = 0
        for b in 0..<Self.bandCount {
            var v = (db[b] - (reference - range)) / range
            v = features.silent ? 0 : min(max(v, 0), 1)
            v = pow(v * v * (3 - 2 * v), 1.25)
            bands[b] = v > bands[b] ? v : bands[b] + (v - bands[b]) * release
            peaks[b] = max(bands[b], peaks[b] - dt * 0.6)
            let f = bandCenter[b]
            all += bands[b]
            if f < 150 { bass += bands[b]; nb += 1 }
            else if f > 250 && f < 2500 { mid += bands[b]; nm += 1 }
            else if f > 4000 { treble += bands[b]; nt += 1 }
        }
        features.bass = dynamics(&bassDyn, raw: bass / max(nb, 1), dt: dt, rawShare: 0.35)
        features.mid = dynamics(&midDyn, raw: mid / max(nm, 1), dt: dt, rawShare: 0.45)
        features.treble = dynamics(&trebleDyn, raw: treble / max(nt, 1), dt: dt, rawShare: 0.45)
        let e = all / Float(Self.bandCount)
        features.energy = e > features.energy ? e : features.energy + (e - features.energy) * (1 - exp(-dt / 0.18))
        if !features.silent { features.lowShare += ((bass / max(nb, 1)) / max(e * 2, 0.05) - features.lowShare) * (1 - exp(-dt / 4)) }
    }

    /// Raw level blended with how far it sits above its recent average: instant attack, quick release.
    private func dynamics(_ d: inout Dyn, raw: Float, dt: Float, rawShare: Float) -> Float {
        d.avg += (raw - d.avg) * (1 - exp(-dt / 2.0))
        d.peak = max(raw, d.peak - dt * 0.12)
        let base = d.avg * 0.85
        let transient = min(max((raw - base) / max(d.peak - base, 0.12), 0), 1)
        let target = rawShare * raw + (1 - rawShare) * transient
        d.out = target > d.out ? target : d.out + (target - d.out) * (1 - exp(-dt / 0.1))
        return min(max(d.out, 0), 1)
    }

    // MARK: Oscilloscope

    private func buildWave(ring: SampleRingBuffer, center: Double, newest: Int, dt: Float) {
        ring.read(into: smallBuf, count: 2048, endingAt: min(Int(center) + 1024, newest))
        let a: Float = 0.18
        var y = smallBuf[0]
        for i in 0..<2048 { y += (smallBuf[i] - y) * a; smooth[i] = y }
        for i in stride(from: 2047, through: 0, by: -1) { y += (smooth[i] - y) * a; smooth[i] = y }

        var trigger = 0
        var bestSlope: Float = 0
        for i in 1..<1024 {
            let s0 = smooth[i - 1], s1 = smooth[i]
            if s0 < 0, s1 >= 0, s1 - s0 > bestSlope { bestSlope = s1 - s0; trigger = i }
        }
        var maxAbs: Float = 0
        smooth.withUnsafeBufferPointer { vDSP_maxmgv($0.baseAddress! + trigger, 1, &maxAbs, 1024) }
        wavePeak = max(maxAbs, wavePeak * exp(-dt / 1.5))
        let norm = 1 / max(wavePeak, 0.02)
        let quiet: Float = features.silent ? 0 : 1
        for i in 0..<Self.waveCount {
            let s = (smooth[trigger + i * 2] + smooth[trigger + i * 2 + 1]) * 0.5 * norm * quiet
            wave[i] += (s - wave[i]) * 0.85
        }
    }
}
