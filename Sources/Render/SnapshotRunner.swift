import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// A made-up dance loop (124 BPM kick, snare, hats, bass, chords) delivered like a real audio
/// device would: 512-frame buffers, stamped with when each sample would be heard.
final class SyntheticFeed: AudioFeed {
    let ring = SampleRingBuffer()
    let sideRing = SampleRingBuffer()
    let sampleRate: Double = 48_000
    /// Adds an off-beat guitar panned to the right, playing notes in the singer's range.
    var guitar = false
    /// Real-drummer feel: every hit a different velocity, a quieter breakdown (14–22 s) and a
    /// pad swell (22–30 s) — the conditions that make a naive detector skip repeats.
    var humanise = false
    var breakdownGain = 0.55

    private func velocity(_ k: Int, salt: UInt32) -> Double {
        var x = UInt32(truncatingIfNeeded: k) &* 2_654_435_761 &+ salt
        x ^= x >> 15; x = x &* 2_246_822_519; x ^= x >> 13
        return 0.7 + 0.3 * Double(x % 1000) / 999
    }
    var bpm = 124.0
    var outputLatency = 0.03
    var deliveryDelay = 0.004
    let startTime: Double
    private var n = 0
    private var seed: UInt32 = 0x1234_5678
    private var hatPrev = 0.0, hatPrev2 = 0.0
    /// Sung syllables (start seconds, length, pitch) mixed over the beat.
    var syllables: [(start: Double, duration: Double, f0: Double)] = []
    private var syllableCursor = 0

    init(startTime: Double = 1000) { self.startTime = startTime }

    var beatLength: Double { 60 / bpm }

    /// Host time at which the kick of beat `k` is heard.
    func kickHeard(_ k: Int) -> Double { startTime + Double(k) * beatLength + outputLatency }

    private func noise() -> Double {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Double(seed) / Double(UInt32.max) * 2 - 1
    }

    /// Deliver every whole buffer whose capture has finished by host time `t`.
    func deliver(until t: Double) {
        let chunk = 512
        while startTime + Double(n + chunk) / sampleRate + deliveryDelay <= t {
            var mid = [Float](repeating: 0, count: chunk)
            var side = [Float](repeating: 0, count: chunk)
            for i in 0..<chunk {
                let (l, r) = sample(Double(n + i) / sampleRate)
                mid[i] = (l + r) * 0.5
                side[i] = (l - r) * 0.5
            }
            mid.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: chunk) }
            side.withUnsafeBufferPointer { sideRing.write($0.baseAddress!, count: chunk) }
            n += chunk
            let captureEnd = startTime + Double(n) / sampleRate
            ring.setStamp(.init(count: n, heardAt: captureEnd + outputLatency, writtenAt: captureEnd + deliveryDelay))
        }
    }

    private func sample(_ t: Double) -> (Float, Float) {
        let beatLen = beatLength
        let chords: [[Double]] = [[220, 261.63, 329.63], [174.61, 220, 261.63], [196, 246.94, 293.66], [164.81, 207.65, 246.94]]
        let bt = t.truncatingRemainder(dividingBy: beatLen)
        let beatIndex = Int(t / beatLen)
        let drumGain = humanise && t >= 14 && t < 22 ? breakdownGain : 1.0
        let kickVel = humanise ? velocity(beatIndex, salt: 7) * drumGain : 1
        let kick = sin(2 * .pi * (48 * bt + 70 * 0.035 * (1 - exp(-bt / 0.035)))) * exp(-bt / 0.2) * 0.85 * kickVel
        let ht = (t + beatLen / 2).truncatingRemainder(dividingBy: beatLen)
        // Hi-hat: noise pushed up above ~6 kHz (second difference), like a real cymbal.
        let raw = noise()
        let bright = humanise ? (raw - 2 * hatPrev + hatPrev2) * 0.5 : raw
        hatPrev2 = hatPrev; hatPrev = raw
        let hat = bright * exp(-ht / 0.025) * 0.12
        let bar = t.truncatingRemainder(dividingBy: beatLen * 2) - beatLen
        let snareVel = humanise ? velocity(beatIndex, salt: 91) * drumGain : 1
        let snare = bar >= 0 ? (noise() * 0.35 + sin(2 * .pi * 190 * bar) * 0.25) * exp(-bar / 0.11) * snareVel : 0
        let chord = chords[Int(t / (beatLen * 8)) % chords.count]
        // Band-limited saw (a naive one aliases into clicks no real mix contains).
        let f0 = chord[0] / 4
        var saw = 0.0
        for h in 1...5 { saw += sin(2 * .pi * f0 * Double(h) * t) / Double(h) }
        let bass = saw * 0.16 * (0.6 + 0.4 * (1 - exp(-bt / 0.1)))
        // Pad: a wide stereo chorus — each side drifts in pitch and phase on its own.
        var padL = 0.0, padR = 0.0
        let driftL = 2.2 * sin(2 * .pi * 0.37 * t), driftR = 2.2 * sin(2 * .pi * 0.23 * t + 2)
        for (i, f) in chord.enumerated() {
            let d = Double(i) * 1.7
            padL += sin(2 * .pi * f * 1.003 * t + driftL + d) + 0.3 * sin(4 * .pi * f * 1.003 * t + driftL * 2)
            padR += sin(2 * .pi * f * 0.9965 * t + driftR - d) + 0.3 * sin(4 * .pi * f * 0.9965 * t - driftR * 2)
        }
        let swell = humanise && t >= 22 && t < 30 ? 1 + 2 * sin(Double.pi * (t - 22) / 8) : 1
        let padGain = 0.045 * (0.8 + 0.2 * sin(2 * .pi * 0.25 * t)) * swell
        var gtr = 0.0
        if guitar {
            let eighth = beatLen / 2
            let k = Int(t / eighth)
            let gt = t - Double(k) * eighth
            let notes = [196.0, 293.66, 246.94, 329.63, 220, 261.63, 392, 293.66]
            let f = notes[k % notes.count]
            for h in 1...8 { gtr += sin(2 * .pi * f * Double(h) * t) * exp(-gt * (4 + Double(h))) / Double(h) }
            gtr *= 0.09 * min(gt / 0.003, 1)
        }
        let center = kick + hat + snare + bass + voice(t)
        let l = center + padL * padGain + gtr * 0.35
        let r = center + padR * padGain + gtr
        return (Float(max(-1, min(1, l))), Float(max(-1, min(1, r))))
    }

    /// A vowel-like tone: harmonics shaped by two formants, vibrato, soft attack and release.
    private func voice(_ t: Double) -> Double {
        guard !syllables.isEmpty else { return 0 }
        while syllableCursor < syllables.count,
              syllables[syllableCursor].start + syllables[syllableCursor].duration + 0.1 < t { syllableCursor += 1 }
        var out = 0.0
        var i = syllableCursor
        while i < syllables.count, syllables[i].start <= t {
            let s = syllables[i]
            let age = t - s.start
            let env = min(age / 0.03, 1) * (age < s.duration ? 1 : max(0, 1 - (age - s.duration) / 0.08))
            if env > 0 {
                // Vibrato as phase: ∫ f0(1 + a·sin ωτ) dτ = f0(τ − (a/ω)·cos ωτ).
                let w = 2 * Double.pi * 5.5
                let cycles = s.f0 * (age - 0.012 / w * cos(w * age))
                var tone = 0.0
                for h in 1...12 {
                    let f = s.f0 * Double(h)
                    let formant = 0.25 + exp(-pow((f - 700) / 260, 2)) + 0.7 * exp(-pow((f - 1900) / 420, 2))
                    tone += sin(2 * .pi * Double(h) * cycles) * formant / pow(Double(h), 0.7)
                }
                out += tone * env * 0.055
            }
            i += 1
        }
        return out
    }
}

enum SnapshotRunner {
    /// `Aura --snapshot <outdir> [--art <image>] [--size WxH] [--hud] [--lyrics] [--latency-test]`
    @MainActor
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let outDir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        if args.contains("--latency-test") { latencyTest(); exit(0) }
        if args.contains("--hop-dump") {
            let feed = SyntheticFeed()
            let analyzer = AudioAnalyzer()
            var t = feed.startTime
            analyzer.onHop = { end, low, high in
                let s = Double(end) / feed.sampleRate
                guard s > 8, s < 9.5 else { return }
                let beatPos = (s / feed.beatLength).truncatingRemainder(dividingBy: 1)
                print(String(format: "end=%.4fs beatPos=%.2f low=%6.2f high=%6.2f %@", s, beatPos, low, high,
                             String(repeating: "#", count: min(Int(low * 4), 60))))
            }
            while t < feed.startTime + 10 {
                t += 1 / 120.0
                feed.deliver(until: t)
                analyzer.update(presentTime: t, dt: 1 / 120.0, ring: feed.ring, side: feed.sideRing, sampleRate: feed.sampleRate)
            }
            exit(0)
        }

        var width = 1600, height = 1000
        if let s = args.firstIndex(of: "--size"), s + 1 < args.count {
            let parts = args[s + 1].split(separator: "x").compactMap { Int($0) }
            if parts.count == 2 { width = parts[0]; height = parts[1] }
        }
        guard let renderer = Renderer() else { print("renderer failed"); exit(1) }
        let feed = SyntheticFeed()
        if let b = args.firstIndex(of: "--bpm"), b + 1 < args.count, let bpm = Double(args[b + 1]) { feed.bpm = bpm }
        renderer.feed = feed

        var cover = Placeholder.cover
        if let a = args.firstIndex(of: "--art"), a + 1 < args.count,
           let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[a + 1]) as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            cover = img
            renderer.setArtwork(img, palette: PaletteExtractor.extract(from: img))
        }

        var t = feed.startTime
        func frame(_ readback: Bool) -> CGImage? {
            t += 1.0 / 60
            feed.deliver(until: t)
            renderer.step(dt: 1.0 / 60, presentTime: t + 1.0 / 60)
            return renderer.renderOffscreen(width: width, height: height, readback: readback)
        }

        if args.contains("--lyrics") {
            renderLyricThemes(outDir: outDir, width: width, height: height, cover: cover, args: args)
            exit(0)
        }
        if args.contains("--lyrics-timing-test") { lyricsTimingTest(); exit(0) }
        if args.contains("--voice-test") { voiceTest(); exit(0) }
        if args.contains("--ring-debug") {
            let feed = SyntheticFeed()
            feed.humanise = true
            let analyzer = AudioAnalyzer()
            var settings = RingSettings()
            settings.mode = .expert
            settings.rules = [RingSettings.Rule(source: .kick, loudness: 0, jump: 0.05)]
            settings.alsoOnBeats = false
            settings.minGap = 0.05
            analyzer.ringSettings = settings
            let beat = feed.beatLength
            var rows: [(phase: Int, rise: Float, jump: Float, level: Float, span: Float, print: Float)] = []
            RingDetector.debug = { t, level, jump, rise, span, printMax in
                guard t > 8, t < 14 else { return }
                let phase = Int(((t / beat).truncatingRemainder(dividingBy: 1) * 16).rounded()) % 16
                rows.append((phase, rise, jump, level, span, printMax))
            }
            var t = feed.startTime
            while t < feed.startTime + 15 {
                t += 1.0 / 120
                feed.deliver(until: t)
                analyzer.update(presentTime: t, dt: 1.0 / 120, ring: feed.ring, side: feed.sideRing, sampleRate: feed.sampleRate)
            }
            for slot in 0..<16 {
                let r = rows.filter { $0.phase == slot }
                guard !r.isEmpty else { continue }
                let rises = r.map(\.rise).sorted(), prints = r.map(\.print).sorted()
                print(String(format: "slot %2d: %2d candidates · rise dB median %.1f max %.1f · level %.2f · fingerprint max median %.1f · span %.1f",
                             slot, r.count, rises[rises.count / 2], rises.last!, r.map(\.level).reduce(0, +) / Float(r.count),
                             prints[prints.count / 2], r[0].span))
            }
            exit(0)
        }
        if args.contains("--tempo-test") {
            BeatTracker.debug = ProcessInfo.processInfo.environment["AURA_TEMPO"] != nil
            for (bpm, humanise) in [(72.0, false), (90.0, false), (110.0, false), (124.0, false), (140.0, false),
                                    (150.0, false), (160.0, false), (174.0, false), (180.0, false),
                                    (72.0, true), (90.0, true), (124.0, true), (150.0, true), (174.0, true)] {
                if BeatTracker.debug { print(String(format: "— fed %.0f BPM (beat = %.1f hops)", bpm, 48000 * 60 / bpm / 256)) }
                let feed = SyntheticFeed()
                feed.bpm = bpm
                feed.humanise = humanise
                feed.outputLatency = 0.17
                let analyzer = AudioAnalyzer()
                var t = feed.startTime
                while t < feed.startTime + 20 {
                    t += 1.0 / 120
                    feed.deliver(until: t)
                    analyzer.update(presentTime: t + 1.0 / 120, dt: 1.0 / 120, ring: feed.ring, side: feed.sideRing, sampleRate: feed.sampleRate)
                }
                let f = analyzer.features
                print(String(format: "played %5.1f BPM%@ → heard %5.1f BPM (lock %.2f) %@", bpm, humanise ? " (live drummer)" : "", f.bpm, f.tempoLock,
                             abs(f.bpm - bpm) < 2 ? "" : (abs(f.bpm * 2 - bpm) < 3 ? "← HALF" : "← WRONG")))
            }
            exit(0)
        }
        if args.contains("--ring-frequency") {
            for bpm in [124.0, 174.0] {
                for frequency in RingSettings.Frequency.allCases {
                    let feed = SyntheticFeed()
                    feed.humanise = true
                    feed.bpm = bpm
                    feed.outputLatency = 0.17
                    let analyzer = AudioAnalyzer()
                    var settings = RingSettings()
                    settings.genre = .pop
                    settings.frequency = frequency
                    analyzer.ringSettings = settings
                    var rings: [Double] = []
                    analyzer.onRing = { sample, _ in rings.append(sample / feed.sampleRate) }
                    var t = feed.startTime
                    while t < feed.startTime + 36 {
                        t += 1.0 / 120
                        feed.deliver(until: t)
                        analyzer.update(presentTime: t + 1.0 / 120, dt: 1.0 / 120, ring: feed.ring, side: feed.sideRing, sampleRate: feed.sampleRate)
                    }
                    let beat = feed.beatLength
                    let inside = rings.filter { $0 > 8 && $0 < 35 }
                    let onBeat = inside.filter { r in abs(r / beat - (r / beat).rounded()) * beat < 0.06 }
                    let every = frequency.beatsPerRing ?? 1
                    var residues = [Int](repeating: 0, count: every)
                    for r in onBeat { residues[Int((r / beat).rounded()) % every] += 1 }
                    let beats = Int(27 / beat)
                    let offsets = onBeat.map { ($0 - ($0 / beat).rounded() * beat) * 1000 }
                    print(String(format: "%3.0f BPM %-28@ rings %3d (a beat has %d → expect ~%d) · on a beat %3d · elsewhere %2d · timing %+.1f ms · beat-of-bar spread %@",
                                 bpm, frequency.title as NSString, inside.count, beats, beats / every, onBeat.count, inside.count - onBeat.count,
                                 offsets.reduce(0, +) / Double(max(offsets.count, 1)), residues.map(String.init).joined(separator: "/")))
                }
            }
            exit(0)
        }
        if args.contains("--ring-miss") {
            let feed = SyntheticFeed()
            feed.humanise = !args.contains("--plain")
            if args.contains("--fast") { feed.bpm = 174 }
            feed.breakdownGain = 0.3
            feed.outputLatency = 0.17
            let analyzer = AudioAnalyzer()
            var settings = RingSettings()
            settings.genre = args.contains("--pop") ? .pop : .electronic
            analyzer.ringSettings = settings
            var rings: [Double] = []
            analyzer.onRing = { sample, _ in rings.append(sample / feed.sampleRate) }
            var candidates: [(t: Double, info: String)] = []
            RingDetector.debugCandidate = { t, info in candidates.append((t, info)) }
            var t = feed.startTime
            while t < feed.startTime + 30 {
                t += 1.0 / 120
                feed.deliver(until: t)
                analyzer.update(presentTime: t + 1.0 / 120, dt: 1.0 / 120, ring: feed.ring, side: feed.sideRing, sampleRate: feed.sampleRate)
            }
            let beat = feed.beatLength
            for k in (Int((args.contains("--misses") ? 6 : 12) / beat) + 1)...Int((args.contains("--misses") ? 29 : 22) / beat) {
                let kick = Double(k) * beat
                let ringed = rings.contains { abs($0 - kick) < 0.06 }
                if args.contains("--misses"), ringed { continue }
                let near = candidates.filter { abs($0.t - kick) < 0.05 && $0.info.hasPrefix("kick") }
                print(String(format: "%.2f %@ ", kick, ringed ? "RING" : "miss") + (near.map { String(format: "%+.0fms ", ($0.t - kick) * 1000) + $0.info }.joined(separator: " | ")))
            }
            exit(0)
        }
        if args.contains("--ring-consistency") {
            for (label, genre) in [("Rock & metal preset (kick + snare)", RingSettings.Genre.rock),
                                   ("Techno & EDM preset (kick)", .electronic), ("Pop preset", .pop)] {
                for (memory, gain) in [(false, 0.55), (true, 0.55), (false, 0.3), (true, 0.3)] {
                    RingDetector.memoryEnabled = memory
                    let feed = SyntheticFeed()
                    feed.humanise = true
                    feed.breakdownGain = gain
                    feed.outputLatency = 0.17
                    let analyzer = AudioAnalyzer()
                    var settings = RingSettings()
                    settings.genre = genre
                    analyzer.ringSettings = settings
                    var rings: [Double] = []
                    analyzer.onRing = { sample, _ in rings.append(sample / feed.sampleRate) }
                    var beatRings: [Double] = [], memoryFires: [Double] = [], fires: [(t: Double, source: String)] = []
                    analyzer.onRingSource = { sample, source in if source == "beat" { beatRings.append(sample / feed.sampleRate) } }
                    RingDetector.debugFire = { t, viaMemory, source in
                        if viaMemory { memoryFires.append(t) }
                        fires.append((t, source))
                    }
                    var t = feed.startTime
                    while t < feed.startTime + 36 {
                        t += 1.0 / 120
                        feed.deliver(until: t)
                        analyzer.update(presentTime: t + 1.0 / 120, dt: 1.0 / 120, ring: feed.ring, side: feed.sideRing, sampleRate: feed.sampleRate)
                    }
                    let beat = feed.beatLength
                    let kicks = (Int(6 / beat) + 1...Int(35 / beat)).map { Double($0) * beat }
                    let snares = kicks.filter { k in Int((k / beat).rounded()) % 2 == 1 }
                    func caught(_ times: [Double], in lo: Double, _ hi: Double) -> String {
                        let inside = times.filter { $0 >= lo && $0 < hi }
                        let hit = inside.filter { x in rings.contains { abs($0 - x) < 0.06 } }.count
                        return "\(hit)/\(inside.count)"
                    }
                    // Where in the beat do rings land? (16 slots; slot 0 = on the kick, 8 = off-beat)
                    var slots = [Int](repeating: 0, count: 16)
                    for r in rings where r > 6 && r < 35 {
                        let phase = (r / beat).truncatingRemainder(dividingBy: 1)
                        slots[Int((phase * 16).rounded()) % 16] += 1
                    }
                    print("   ring positions in the beat (16 slots): \(slots.map(String.init).joined(separator: " "))")
                    let hats = kicks.map { $0 + beat / 2 }
                    let onHats = rings.filter { r in r > 6 && r < 35 && hats.contains { abs(r - $0) < 0.06 } }.count
                    let extra = rings.filter { r in r > 6 && r < 35 && !kicks.contains { abs(r - $0) < 0.06 } && !hats.contains { abs(r - $0) < 0.06 } }.count
                    print(String(format: "%-36@ breakdown %2.0f%% memory %@ · kicks %@ %@ %@ · snares %@ %@ %@ · on hi-hats %d/%d · other %d",
                                 label as NSString, gain * 100, memory ? "on " : "off",
                                 caught(kicks, in: 6, 14), caught(kicks, in: 14, 22), caught(kicks, in: 22, 30),
                                 caught(snares, in: 6, 14), caught(snares, in: 14, 22), caught(snares, in: 22, 30),
                                 onHats, hats.filter { $0 > 6 && $0 < 35 }.count, extra))
                    let strays = rings.filter { r in r > 6 && r < 35 && !kicks.contains { abs(r - $0) < 0.06 } }
                    let fromBeats = strays.filter { r in beatRings.contains { abs($0 - r) < 0.001 } }.count
                    let fromMemory = strays.filter { r in memoryFires.contains { abs($0 - r) < 0.03 } }.count
                    let rescued = memoryFires.filter { f in f > 6 && f < 35 && kicks.contains { abs(f - $0) < 0.06 } }.count
                    print("      strays: \(strays.count) (beat detector \(fromBeats), memory \(fromMemory)) · memory rescued \(rescued) drum hits")
                    if !memory {
                        var timing: [String] = []
                        for source in Set(fires.map(\.source)).sorted() {
                            let offs = fires.filter { $0.source == source && $0.t > 6 && $0.t < 35 }
                                .compactMap { f in kicks.map { f.t - $0 }.min(by: { abs($0) < abs($1) }) }.filter { abs($0) < 0.06 }
                            guard !offs.isEmpty else { continue }
                            timing.append(String(format: "%@ %+.1f ms (n=%d)", source, offs.reduce(0, +) / Double(offs.count) * 1000, offs.count))
                        }
                        let beatOffs = beatRings.filter { $0 > 6 && $0 < 35 }.compactMap { f in kicks.map { f - $0 }.min(by: { abs($0) < abs($1) }) }.filter { abs($0) < 0.06 }
                        timing.append(String(format: "beats %+.1f ms (n=%d)", beatOffs.reduce(0, +) / Double(max(beatOffs.count, 1)) * 1000, beatOffs.count))
                        print("      timing vs drum hit: " + timing.joined(separator: " · "))
                    }
                    if ProcessInfo.processInfo.environment["AURA_STRAYS"] != nil, !memory {
                        let list = strays.map { r -> String in
                            let slot = Int(((r / beat).truncatingRemainder(dividingBy: 1) * 16).rounded()) % 16
                            let src = beatRings.contains { abs($0 - r) < 0.001 } ? "B" : "T"
                            return String(format: "%.2f/%d%@", r, slot, src)
                        }
                        print("      " + list.joined(separator: " "))
                    }
                }
            }
            exit(0)
        }
        if args.contains("--rings-test") {
            for (label, bpm, latency) in [("124 BPM, AirPods", 124.0, 0.17), ("174 BPM, AirPods", 174.0, 0.17),
                                          ("174 BPM, speakers + look-ahead", 174.0, 0.087)] {
                let feed = SyntheticFeed()
                feed.bpm = bpm
                feed.outputLatency = latency
                let analyzer = AudioAnalyzer()
                var rings: [Double] = []
                analyzer.onRing = { sample, _ in rings.append(sample / feed.sampleRate) }
                var t = feed.startTime
                while t < feed.startTime + 30 {
                    t += 1.0 / 120
                    feed.deliver(until: t)
                    analyzer.update(presentTime: t + 1.0 / 120, dt: 1.0 / 120, ring: feed.ring, side: feed.sideRing, sampleRate: feed.sampleRate)
                }
                let beat = 60 / bpm
                let kicks = (Int(6 / beat) + 1...Int(29 / beat)).map { Double($0) * beat }
                let offsets = kicks.compactMap { k in rings.map { $0 - k }.filter { abs($0) < 0.06 }.min(by: { abs($0) < abs($1) }) }
                let extra = rings.filter { r in r > 6 && r < 29 && !kicks.contains { abs(r - $0) < 0.06 } }.count
                let maxAlive = rings.map { r in rings.filter { $0 <= r && r - $0 < 1.1 }.count }.max() ?? 0
                print(String(format: "%-32@ kicks with a ring %d/%d · timing %+.1f ms (worst %.0f) · other rings %d · most on screen at once %d",
                             label as NSString, offsets.count, kicks.count,
                             offsets.reduce(0, +) / Double(max(offsets.count, 1)) * 1000, (offsets.map(abs).max() ?? 0) * 1000,
                             extra, min(maxAlive, 8)))
            }
            exit(0)
        }
        if args.contains("--voice-dump") {
            let script = makeScript()
            let sung = script.words.flatMap { $0 }
            for withVoice in [true, false] {
                let feed = SyntheticFeed()
                if withVoice { feed.syllables = script.syllables }
                let analyzer = AudioAnalyzer()
                var t = feed.startTime
                var nextPrint = 14.0
                print(withVoice ? "=== with voice" : "=== backing only")
                while t < feed.startTime + 24 {
                    t += 1.0 / 120
                    feed.deliver(until: t)
                    analyzer.update(presentTime: t, dt: 1.0 / 120, ring: feed.ring, side: feed.sideRing, sampleRate: feed.sampleRate)
                    let st = t - feed.startTime - 0.02
                    if st >= nextPrint {
                        nextPrint += 0.1
                        let v = analyzer.vocal
                        let truth = sung.contains { st >= $0.start && st <= $0.start + $0.duration }
                        print(String(format: "t=%5.1f %@ voiced=%.5f total=%.5f ratio=%.3f ref=%.3f..%.3f act=%.2f %@",
                                     st, truth ? "SING" : "    ", v.lastVoiced, v.lastTotal, v.smoothed, v.lowRef, v.highRef, v.activity,
                                     String(repeating: "#", count: Int(v.activity * 20))))
                    }
                }
            }
            exit(0)
        }

        if args.contains("--hud") {
            renderer.setMode(.halo)
            for _ in 0..<150 { _ = frame(false) }
            guard let img = frame(true) else { exit(1) }
            renderHUDPreview(frame: img, cover: cover, outDir: outDir, width: width, height: height)
            exit(0)
        }

        let modes = args.contains("--mode") ? VisualMode.allCases.filter { args.contains($0.title.lowercased()) } : VisualMode.allCases
        for mode in modes {
            renderer.setMode(mode)
            for f in 0..<240 {
                if let img = frame(f == 239) {
                    save(img, to: outDir.appendingPathComponent("\(mode.number)-\(mode.title.lowercased()).png"))
                }
            }
            let s = renderer.analyzer.features
            print(String(format: "%@  bass=%.2f mid=%.2f treble=%.2f energy=%.2f beats=%d bpm=%.1f lock=%.2f",
                         mode.title, s.bass, s.mid, s.treble, s.energy, s.beatCount, s.bpm, s.tempoLock))
        }
        exit(0)
    }

    // MARK: Latency test

    /// Plays the synthetic loop through a simulated device and measures when each beat flash
    /// appears on screen relative to when its kick is heard.
    private static func latencyTest() {
        for (label, latency) in [("speakers, no look-ahead", 0.027), ("speakers + look-ahead", 0.083), ("bluetooth", 0.17)] {
            let feed = SyntheticFeed()
            feed.outputLatency = latency
            let analyzer = AudioAnalyzer()
            let fps = 120.0
            var t = feed.startTime
            var lastCount = 0
            var flashes: [Double] = []
            var lowOffsets: [Double] = [], highOffsets: [Double] = []
            var predicted = 0
            let rate = feed.sampleRate
            func nearestKickOffsetMs(_ sample: Double) -> Double {
                let beats = sample / rate / feed.beatLength
                return (beats - beats.rounded()) * feed.beatLength * 1000
            }
            analyzer.onDetect = { sample, _, low in
                guard sample / rate > 6 else { return }
                if low { lowOffsets.append(nearestKickOffsetMs(sample)) } else { highOffsets.append(nearestKickOffsetMs(sample)) }
            }
            analyzer.onFire = { _, wasPredicted in if wasPredicted { predicted += 1 } }
            let duration = 24.0
            while t < feed.startTime + duration {
                t += 1 / fps
                feed.deliver(until: t)
                let present = t + 1 / fps
                analyzer.update(presentTime: present, dt: 1 / fps, ring: feed.ring, side: feed.sideRing, sampleRate: feed.sampleRate)
                if analyzer.features.beatCount != lastCount {
                    lastCount = analyzer.features.beatCount
                    flashes.append(present)
                }
            }
            // Match each heard kick (after a 6 s warm-up) to the nearest flash.
            var errors: [Double] = []
            var missed = 0
            var k = Int(6 / feed.beatLength)
            while feed.kickHeard(k) < feed.startTime + duration - 1 {
                let heard = feed.kickHeard(k)
                if let nearest = flashes.min(by: { abs($0 - heard) < abs($1 - heard) }), abs(nearest - heard) < 0.12 {
                    errors.append((nearest - heard) * 1000)
                } else { missed += 1 }
                k += 1
            }
            let extra = flashes.filter { f in f > feed.startTime + 6 && !(0..<200).contains(where: { abs(feed.kickHeard($0) - f) < 0.12 }) }.count
            let mean = errors.reduce(0, +) / Double(max(errors.count, 1))
            let worst = errors.map(abs).max() ?? 0
            print(String(format: "%-26@ flash vs kick: mean %+.1f ms, worst %.1f ms, missed %d, extra %d · bpm %.1f lock %.2f lookahead %.0f ms",
                         label as NSString, mean, worst, missed, extra, analyzer.features.bpm, analyzer.features.tempoLock,
                         analyzer.features.lookAhead * 1000))
            let hist = { (xs: [Double]) -> String in
                Dictionary(grouping: xs.map { Int(($0 / 20).rounded()) * 20 }, by: { $0 })
                    .sorted { $0.key < $1.key }.map { "\($0.key)ms×\($0.value.count)" }.joined(separator: " ")
            }
            let near = lowOffsets.filter { abs($0) < 60 }, nearHigh = highOffsets.filter { abs($0) < 60 }
            print(String(format: "   low: %d near kicks (mean %+.1f ms), %d elsewhere · high: %d near kicks (mean %+.1f ms)",
                         near.count, near.reduce(0, +) / Double(max(near.count, 1)), lowOffsets.count - near.count,
                         nearHigh.count, nearHigh.reduce(0, +) / Double(max(nearHigh.count, 1))))
            print("   low onsets rel. to kick: \(hist(lowOffsets))")
            print("   predicted fires: \(predicted)")
        }
    }

    // MARK: Lyric timing

    /// A made-up song. Words come at a steady pace with natural variation, some lines hold a
    /// note or pause mid-line, and lines are separated by short breaths or long instrumental
    /// gaps. The lyric file is early by 0.4 s with ±0.12 s of per-line jitter (a sloppy
    /// community file) and "Spotify" reports its position 0.1 s ahead.
    struct Script {
        var words: [[(text: String, start: Double, duration: Double)]] = []
        var lyrics: Lyrics
        let fileEarly = 0.4
        let spotifyAhead = 0.1
        var syllables: [(start: Double, duration: Double, f0: Double)] {
            words.flatMap { $0 }.enumerated().map { i, w in (w.start, w.duration, [220.0, 247, 262, 294, 330, 262][i % 6]) }
        }
    }

    static func makeScript(trackID: String = "timing-test", pace: Double = 0.42, seed start: UInt32 = 0xA11CE) -> Script {
        var seed = start
        func rand() -> Double { seed = seed &* 1_664_525 &+ 1_013_904_223; return Double(seed) / Double(UInt32.max) }
        let vocab = ["neon", "light", "running", "through", "the", "city", "tonight", "we", "never", "sleep",
                     "hold", "on", "golden", "hours", "fading", "away", "call", "my", "name", "again", "under", "a", "silver", "moon"]
        var words: [[(String, Double, Double)]] = []
        var lines: [LyricLine] = []
        var t = 6.0
        for k in 0..<16 {
            let count = 4 + (k * 7) % 5
            var line: [(String, Double, Double)] = []
            for w in 0..<count {
                let text = vocab[(k * 5 + w * 3) % vocab.count]
                let syl = Double(WordTiming.syllables(text))
                var step = pace * (0.75 + 0.25 * syl) * (0.85 + 0.3 * rand())
                if k % 3 == 1, w == count - 2 { step = 1.1 }                 // held note
                let dur = min(step * 0.8, step - 0.05)
                line.append((text, t, dur))
                t += step
                if k % 4 == 2, w == 2 { t += 0.7 }                           // pause mid-line
            }
            words.append(line)
            let stamp = line[0].1 - 0.4 + (rand() - 0.5) * 0.24
            lines.append(LyricLine(time: stamp, text: line.map(\.0).joined(separator: " ")))
            t += [0.35, 1.0, 3.2][k % 3] + rand() * 0.3
        }
        var script = Script(lyrics: Lyrics(trackID: trackID, lines: lines, instrumental: false))
        script.words = words
        return script
    }

    private static func lyricsTimingTest() {
        for (song, pace, guitar) in [("steady pop song", 0.42, false), ("same, with a panned guitar", 0.42, true),
                                     ("fast song", 0.27, true)] {
            let script = makeScript(pace: pace)
            let truth = script.words
            print("── \(song) ──")
            // Target: words show up `lead` seconds before they're sung.
            let lead = LyricTheme.bubbles.appearLead
            func report(_ label: String, _ errors: [Double]) {
                guard !errors.isEmpty else { print("\(label): no words appeared"); return }
                let ms = errors.map { ($0 + lead) * 1000 }.sorted()           // 0 = exactly on target
                let early = ms.filter { $0 < -150 }.count, late = ms.filter { $0 > 200 }.count
                let p90 = ms.map(abs).sorted()[Int(Double(ms.count - 1) * 0.9)]
                print(String(format: "  %-30@ vs target: median %+5.0f ms · >0.15 s too early %2d%% · >0.2 s too late %2d%% · 90%% within %4.0f ms",
                             label as NSString, ms[ms.count / 2], early * 100 / ms.count, late * 100 / ms.count, p90))
            }

            var old: [Double] = []
            for (k, line) in script.lyrics.lines.enumerated() {
                let next = k + 1 < script.lyrics.lines.count ? script.lyrics.lines[k + 1].time : line.time + 4
                let span = min(max(next - line.time, 0.5) * 0.55, Double(truth[k].count) * 0.3, 2.2)
                let total = Double(truth[k].reduce(0) { $0 + $1.text.count })
                var chars = 0.0
                for w in truth[k] {
                    old.append(line.time - 0.18 + span * chars / total - script.spotifyAhead - w.start)
                    chars += Double(w.text.count)
                }
            }
            report("before (previous build)", old)

            for (label, voice, learn, wordByWord) in [("song pace from the lyrics", false, false, true), ("+ waiting for the singer", true, false, true),
                                                      ("+ learning the song's offset", true, true, true),
                                                      ("line by line (default)", true, true, false)] {
                guard let renderer = Renderer() else { return }
                let feed = SyntheticFeed()
                feed.outputLatency = 0.17
                feed.guitar = guitar
                feed.syllables = script.syllables
                renderer.feed = feed
                renderer.lyrics.useVoiceOnsets = voice
                renderer.lyrics.learnOffsets = learn
                renderer.lyrics.wordByWord = wordByWord
                var errors: [Double] = []
                var detail: [(line: Int, index: Int, error: Double)] = []
                renderer.lyrics.onWordAppear = { line, index, songTime in
                    guard line < truth.count, index < truth[line].count else { return }
                    let e = songTime - script.spotifyAhead - truth[line][index].start
                    errors.append(e)
                    detail.append((line, index, e))
                }
                renderer.setLyrics(script.lyrics)
                renderer.setPlayback(PlaybackClock(trackID: script.lyrics.trackID, position: script.spotifyAhead,
                                                   hostTime: feed.startTime + feed.deliveryDelay, playing: true))
                var t = feed.startTime
                while t < feed.startTime + (truth.last?.last?.start ?? 60) + 3 {
                    t += 1.0 / 60
                    feed.deliver(until: t)
                    renderer.step(dt: 1.0 / 60, presentTime: t + 1.0 / 60)
                }
                report(label, errors)
                let vl = renderer.lyrics.vocalInLines, vg = renderer.lyrics.vocalInGaps
                print(String(format: "     words shown %d, skipped %d of %d · singing in lines %.2f (n=%d) gaps %.2f (n=%d) · learned %@",
                             renderer.lyrics.wordsShown, renderer.lyrics.wordsSkipped, truth.flatMap { $0 }.count,
                             vl.sum / Double(max(vl.count, 1)), vl.count, vg.sum / Double(max(vg.count, 1)), vg.count,
                             renderer.lyrics.learner.estimate.map { String(format: "%+.2f", $0) } ?? "-"))
                if !wordByWord {
                    report("     first word of each line", detail.filter { $0.index == 0 }.map(\.error))
                    report("     first word, lines 8+ (offset settled)", detail.filter { $0.index == 0 && $0.line >= 7 }.map(\.error))
                    let lineGap = (0..<truth.count).compactMap { l -> Double? in
                        let shown = detail.filter { $0.line == l }.map(\.error)
                        guard let first = shown.first, let last = shown.last else { return nil }
                        return last - first + (truth[l].last!.start - truth[l].first!.start)
                    }
                    print(String(format: "     whole line on screen within %.2f s of its first word (worst line)", lineGap.max() ?? 0))
                }
                if learn, wordByWord {
                    print(String(format: "     song pace: from lyrics %.2f → after listening %.2f syllables/s",
                                 WordTiming.songRate(script.lyrics.lines), renderer.lyrics.songRate))
                    for (l, line) in truth.enumerated() where l >= 8 && l <= 11 {
                        let desc = line.enumerated().map { i, w -> String in
                            let e = detail.first { $0.line == l && $0.index == i }?.error ?? .nan
                            return String(format: "%@(%d syl, sung %.2f–%.2f, err %+.2f)", w.text, WordTiming.syllables(w.text), w.start, w.start + w.duration, e)
                        }
                        print("       L\(l) stamp \(String(format: "%.2f", script.lyrics.lines[l].time)): " + desc.joined(separator: " "))
                    }
                    let firsts = detail.filter { $0.index == 0 }.map(\.error), others = detail.filter { $0.index > 0 }.map(\.error)
                    let lateLines = detail.filter { $0.line >= 7 }.map(\.error)
                    report("     first word of each line", firsts)
                    report("     other words", others)
                    report("     lines 8+ (offset settled)", lateLines)
                    let perLine = (0..<truth.count).map { l -> String in
                        let e = detail.filter { $0.line == l }.map { Int(($0.error * 1000 / 50).rounded()) * 50 }
                        return "L\(l):" + e.map { $0 >= 0 ? "+\($0)" : "\($0)" }.joined(separator: ",")
                    }
                    print("     per word (ms, rounded):")
                    for chunk in stride(from: 0, to: perLine.count, by: 4) { print("       " + perLine[chunk..<min(chunk + 4, perLine.count)].joined(separator: "  ")) }
                    print(String(format: "     learned offset %@ (true %.2f s) from %d lines",
                                 renderer.lyrics.learner.estimate.map { String(format: "%+.2f s", $0) } ?? "none",
                                 script.fileEarly + script.spotifyAhead, renderer.lyrics.learner.samples.count))
                }
            }
        }
    }

    /// How well "is someone singing" tracks the made-up vocals, and when phrase starts are reported.
    private static func voiceTest() {
        let script = makeScript()
        let sung = script.words.flatMap { $0 }
        func singingTruth(_ t: Double) -> Bool {
            sung.contains { t >= $0.start && t <= $0.start + $0.duration + 0.12 }
        }
        let phraseStarts = sung.enumerated().filter { i, w in
            i == 0 || w.start - (sung[i - 1].start + sung[i - 1].duration) > 0.25
        }.map { $0.element.start }

        for guitar in [false, true] {
            for centre in [false, true] {
                let feed = SyntheticFeed()
                feed.outputLatency = 0.17
                feed.guitar = guitar
                feed.syllables = script.syllables
                let analyzer = AudioAnalyzer()
                analyzer.vocal.useCenter = centre
                var starts: [Double] = []
                var agree = 0, total = 0, falseOn = 0, falseOff = 0
                var t = feed.startTime
                let end = (sung.last?.start ?? 60) + 2
                while t < feed.startTime + end {
                    t += 1.0 / 120
                    feed.deliver(until: t)
                    analyzer.update(presentTime: t, dt: 1.0 / 120, ring: feed.ring, side: feed.sideRing, sampleRate: feed.sampleRate)
                    for o in analyzer.voiceOnsetsThisFrame { starts.append(o.sample / feed.sampleRate) }
                    let songT = t - feed.startTime - 0.2
                    guard songT > 8 else { continue }
                    let on = analyzer.vocalActivity(atSample: songT * feed.sampleRate) > 0.5
                    let truth = singingTruth(songT)
                    total += 1
                    if on == truth { agree += 1 } else if on { falseOn += 1 } else { falseOff += 1 }
                }
                let matched = phraseStarts.compactMap { p in starts.map { $0 - p }.filter { abs($0) < 0.3 }.min(by: { abs($0) < abs($1) }) }
                let stray = starts.filter { s in !phraseStarts.contains { abs(s - $0) < 0.3 } }.count
                print(String(format: "%@ centre %@ · singing right %2d%% (false on %2d%%, missed %2d%%) · phrase starts %2d/%d found, offset %+4.0f ms, %d false",
                             guitar ? "guitar" : "      ", centre ? "on " : "off",
                             agree * 100 / max(total, 1), falseOn * 100 / max(total, 1), falseOff * 100 / max(total, 1),
                             matched.count, phraseStarts.count,
                             matched.reduce(0, +) / Double(max(matched.count, 1)) * 1000, stray))
            }
        }
    }

    @MainActor
    private static func renderLyricThemes(outDir: URL, width: Int, height: Int, cover: CGImage, args: [String]) {
        let script = makeScript(trackID: "preview")
        let line = script.words.firstIndex { $0.count >= 7 } ?? 0       // a long line
        let captureAt = script.words[line][min(3, script.words[line].count - 1)].start + 0.2   // mid-line
        let mode = VisualMode.allCases.first { args.contains($0.title.lowercased()) } ?? .halo
        let only = LyricTheme.allCases.filter { args.contains($0.title.lowercased()) }
        for theme in only.isEmpty ? LyricTheme.allCases : only {
            guard let renderer = Renderer() else { return }
            let feed = SyntheticFeed()
            feed.outputLatency = 0.17
            feed.syllables = script.syllables
            renderer.feed = feed
            renderer.setArtwork(cover, palette: PaletteExtractor.extract(from: cover))
            renderer.setMode(mode)
            renderer.setLyricTheme(theme)
            renderer.setHUDVisible(false)
            renderer.setLyrics(script.lyrics, learnedOffset: script.fileEarly)
            renderer.setPlayback(PlaybackClock(trackID: "preview", position: 0,
                                               hostTime: feed.startTime + feed.deliveryDelay, playing: true))
            var t = feed.startTime
            let skipTo = script.words[line][0].start - 2.5
            while t < feed.startTime + captureAt {
                t += 1.0 / 60
                feed.deliver(until: t)
                renderer.step(dt: 1.0 / 60, presentTime: t + 1.0 / 60)
                if t - feed.startTime > skipTo { _ = renderer.renderOffscreen(width: width / 2, height: height / 2, readback: false) }
            }
            if let img = renderer.renderOffscreen(width: width, height: height, readback: true) {
                save(img, to: outDir.appendingPathComponent("lyrics-\(theme.rawValue)-\(theme.title.lowercased()).png"))
            }
        }
        print("lyric theme previews written")
    }

    // MARK: HUD preview

    @MainActor
    private static func renderHUDPreview(frame: CGImage, cover: CGImage, outDir: URL, width: Int, height: Int) {
        let model = AppModel()
        model.loadPreview(track: .init(id: "spotify:track:preview", name: "Night Drive", artist: "Neon Coast",
                                       album: "Midnight Radio", duration: 214, artworkURL: ""), cover: cover)
        let pointSize = CGSize(width: CGFloat(width) / 2, height: CGFloat(height) / 2)
        let hud = ZStack {
            Image(decorative: frame, scale: 2).resizable()
            HUD(showChrome: true)
        }
        .environment(model)
        .foregroundStyle(Tokens.ink)
        .frame(width: pointSize.width, height: pointSize.height)
        .environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: hud)
        r.scale = 2
        if let image = r.cgImage { save(image, to: outDir.appendingPathComponent("hud.png")) }

        for tab in SettingsPanel.Tab.allCases {
            let settings = SettingsPanel(scrolls: false, tab: tab).environment(model).environment(\.colorScheme, .dark)
            let r3 = ImageRenderer(content: settings)
            r3.scale = 2
            if let image = r3.cgImage { save(image, to: outDir.appendingPathComponent("settings-\(tab.rawValue.lowercased()).png")) }
        }
        let saved = model.ringSettings
        let hadSaved = UserDefaults.standard.object(forKey: "ringSettings") != nil
        model.ringSettings.mode = .expert
        let expert = SettingsPanel(scrolls: false, tab: .rings).environment(model).environment(\.colorScheme, .dark)
        let r4 = ImageRenderer(content: expert)
        r4.scale = 2
        if let image = r4.cgImage { save(image, to: outDir.appendingPathComponent("settings-rings-expert.png")) }
        model.ringSettings = saved
        if !hadSaved { UserDefaults.standard.removeObject(forKey: "ringSettings") }
        print("HUD previews written")
    }

    private static func save(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
