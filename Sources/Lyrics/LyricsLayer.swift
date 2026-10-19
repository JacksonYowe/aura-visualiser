import CoreText
import Foundation
import Metal
import simd

/// Must match `struct LyricInstance` in Shaders/96_LyricsCommon.msl (16 floats).
struct LyricGPU {
    var cx: Float = 0, cy: Float = 0, size: Float = 0, alpha: Float = 0
    var u0: Float = 0, v0: Float = 0, du: Float = 0, dv: Float = 0
    var textAspect: Float = 1, textScale: Float = 0, seed: Float = 0, pop: Float = 0
    var progress: Float = 0, rotation: Float = 0, appear: Float = 0, glow: Float = 0
}

/// Lyrics drawn in the chosen theme, one item per word. Runs on the render thread.
/// Coordinates are in screen-height units: x ∈ ±aspect/2, y ∈ ±0.5, +y is down.
///
/// Timing: "lyric time" = song position minus the song's offset. Each word has a guessed start;
/// it appears on the first vocal onset near that guess (or when the guess window runs out),
/// and the rest of the line follows the singer's pace.
final class LyricsLayer {
    let atlas: MTLTexture
    /// Three of everything the GPU reads while a frame is in flight, used round-robin.
    private let instanceRing: [MTLBuffer]
    private var instanceSlot = 0
    var instances: MTLBuffer { instanceRing[instanceSlot] }
    var instanceCount = 0
    private(set) var atlasNeedsMipmaps = false

    var enabled = true
    /// Off: each line appears whole when it starts. On: word by word, following the singer (experimental).
    var wordByWord = false
    /// Seconds the words run ahead of the singer.
    var lead: Double = 0.1
    var stageY: Float = 0.32
    private(set) var theme: LyricTheme = .bubbles

    /// Offset the user chose for this song (nil = automatic).
    var manualOffset: Double?
    /// Starting point for songs without a learned offset.
    var priorOffset: Double = 0
    private(set) var learner = LyricOffsetLearner()
    private(set) var autoOffset: Double = 0
    var offset: Double { manualOffset ?? autoOffset }

    static let maxInstances = 256
    var maxInstances: Int { Self.maxInstances }
    static let atlasW = 2048, pageH = 1024, pages = 3, fontPx: CGFloat = 76
    private var fonts: [LyricTheme: CTFont] = [:]
    private let pageBuffer: UnsafeMutablePointer<UInt8>
    private var page = 0

    private(set) var lyrics: Lyrics?
    private var lineIndex = -1
    private var lastSongTime: Double?
    private var pendingOnsets: [Double] = []                          // lyric time, not yet used
    private var onsetHistory: [(time: Double, strength: Float)] = []  // song time
    private var learnCursor = 0
    private(set) var songRate = 3.2
    /// Words shown vs. words whose line ended before they appeared (this song).
    private(set) var wordsShown = 0
    private(set) var wordsSkipped = 0
    /// Diagnostics: average singing detected while lines are sung vs. during long instrumental gaps.
    private(set) var vocalInLines = (sum: 0.0, count: 0)
    private(set) var vocalInGaps = (sum: 0.0, count: 0)
    private var initialRate = 3.2
    private var observedRates: [Double] = []
    private var singingState = false
    private var quietFrom = -Double.infinity
    private var lineVoiceStart: Double?
    private var lineVoiceEnd: Double?
    private var lineSyllables = 0
    private var holdShift = 0.0
    private var lineSpawnTime = -Double.infinity
    private var lineEnd = Double.infinity                 // lyric time this line gets replaced
    private var lineShownAt: Double?                      // line by line: when this line appeared
    private var holdsOffForLine = false
    private var lastAppearTime = -Double.infinity
    private var lastSinging = -Double.infinity
    private var lastPhraseStart = -Double.infinity

    var words: [Word] = []
    var particles: [Particle] = []
    var songAdvancing = false
    private var previousRaw: Double?

    // Test hooks / switches.
    var useVoiceOnsets = true
    /// Tests: wait on the singer even before the song's detector quality is known.
    var ignoreVoiceTrust = false
    var learnOffsets = true
    var onWordAppear: ((_ line: Int, _ index: Int, _ songTime: Double) -> Void)?
    var lastBeatCount = 0
    var clock: Double = 0
    var rng = SystemRandomNumberGenerator()

    struct Word {
        var rect: SIMD4<Float>
        var aspect: Float
        var line: Int
        var index: Int
        var guess: Double
        var duration: Double
        var appearAt: Double?
        var appearClock = 0.0
        var spawnClock = 0.0
        var home: SIMD2<Float>
        var pos: SIMD2<Float>
        var vel = SIMD2<Float>.zero
        var drift: Float = 0
        var size: Float
        var popAt = Double.infinity
        var seed: Float
        var rotation: Float
        var popped = false
        var sparkAccum: Float = 0
    }

    struct Particle {
        var pos: SIMD2<Float>, vel: SIMD2<Float>, radius: Float, born: Double, life: Double, seed: Float
    }

    init?(device: MTLDevice) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: Self.atlasW,
                                                            height: Self.pageH * Self.pages, mipmapped: true)
        desc.usage = .shaderRead
        let instanceBytes = MemoryLayout<LyricGPU>.stride * Self.maxInstances
        let buffers = (0..<Self.pages).compactMap { _ in device.makeBuffer(length: instanceBytes, options: .storageModeShared) }
        guard let atlas = device.makeTexture(descriptor: desc), buffers.count == Self.pages else { return nil }
        precondition(MemoryLayout<LyricGPU>.stride == 64)
        self.atlas = atlas
        instanceRing = buffers
        pageBuffer = .allocate(capacity: Self.atlasW * Self.pageH)
        pageBuffer.initialize(repeating: 0, count: Self.atlasW * Self.pageH)
    }

    deinit { pageBuffer.deallocate() }

    func nextInstanceSlot() { instanceSlot = (instanceSlot + 1) % instanceRing.count }

    // MARK: Inputs

    func setLyrics(_ new: Lyrics?) {
        guard new != lyrics else { return }
        lyrics = new
        songRate = new.map { WordTiming.songRate($0.lines) } ?? 3.2
        initialRate = songRate
        observedRates.removeAll()
        wordsShown = 0
        wordsSkipped = 0
        vocalInLines = (0, 0)
        vocalInGaps = (0, 0)
        lineVoiceStart = nil
        lineVoiceEnd = nil
        popAll(stagger: 0.03)
        lineIndex = -1
        learner.reset()
        autoOffset = priorOffset
        pendingOnsets.removeAll()
        onsetHistory.removeAll()
        learnCursor = 0
    }

    /// Starts this song from an offset learned in a previous session.
    func seedAutoOffset(_ value: Double?) { autoOffset = value ?? priorOffset }

    func setTheme(_ t: LyricTheme) {
        guard t != theme else { return }
        theme = t
        words.removeAll()
        particles.removeAll()
        lineIndex = -1                      // the current line re-spawns in the new style
    }

    func mipmapsGenerated() { atlasNeedsMipmaps = false }

    // MARK: Frame update

    /// - Parameters:
    ///   - songTime: position (seconds) of the audio being heard, or nil when unknown.
    ///   - voiceOnsets: vocal onsets heard this frame, in song time.
    func update(songTime: Double?, voiceOnsets: [(time: Double, strength: Float)], singingNow: Float, singingSoon: Float, dt: Double,
                aspect: Float, beat: Float, beatCount: Int, bass: Float) {
        clock += dt
        let raw = enabled ? songTime : nil
        songAdvancing = raw != nil && raw != previousRaw
        previousRaw = raw

        if let raw, let lyrics, !lyrics.lines.isEmpty {
            if let last = lastSongTime, raw < last - 1.0 || raw > last + 3.0 {
                popAll(stagger: 0)
                lineIndex = -1
                pendingOnsets.removeAll()
                learnCursor = lyrics.lines.firstIndex { $0.time > raw - 1 } ?? lyrics.lines.count
            }
            lastSongTime = raw

            // Ease towards the learned offset so words don't jump when it changes.
            let target = learner.estimate ?? priorOffset
            autoOffset += (target - autoOffset) * min(1, dt * 1.5)

            let lt = raw - offset + lead
            for o in voiceOnsets {
                onsetHistory.append(o)
                pendingOnsets.append(o.time - offset)
            }
            onsetHistory.removeAll { $0.time < raw - 12 }
            pendingOnsets.removeAll { $0 < lt - 1.5 }

            var idx = -1
            for (i, line) in lyrics.lines.enumerated() where line.time - 0.25 <= lt { idx = i }
            if idx != lineIndex {
                popAll(stagger: 0.03)
                lineIndex = idx
                if idx >= 0 { spawn(line: idx, in: lyrics, aspect: aspect, lyricTime: lt) }
            } else if idx >= 0 {
                let line = lyrics.lines[idx]
                let next = idx + 1 < lyrics.lines.count ? lyrics.lines[idx + 1].time : line.time + 6
                if lt > min(next, line.time + 10) + 1.5 { popAll(stagger: 0.03) }
            }
            trigger(lyricTime: lt, singingNow: singingNow, singingSoon: singingSoon)
            if songAdvancing { sampleVocalStats(lyrics: lyrics, lyricTime: lt, singing: singingNow) }
            learn(songTime: raw, lyrics: lyrics)
        } else if !words.isEmpty {
            popAll(stagger: 0.02)
            lastSongTime = nil
        }

        let lt = raw.map { $0 - offset + lead }
        simulate(dt: Float(min(dt, 1.0 / 30)), beat: beat, beatCount: beatCount)
        writeInstances(lyricTime: lt, beat: beat)
    }

    func popAll(stagger: Double) {
        var k = 0.0
        for i in words.indices where words[i].popAt == .infinity {
            if words[i].appearAt == nil { wordsSkipped += 1 }
            words[i].popAt = clock + k
            if words[i].appearAt != nil { k += stagger }
        }
    }

    // MARK: Word timing

    /// Shows the next word when it's due — but not while the singer is silent. A word that's due
    /// during a break waits for singing to start again (up to a limit), and the rest of the line
    /// shifts with it. A singer coming in slightly before the lyric stamp pulls the line forward.
    private func trigger(lyricTime lt: Double, singingNow: Float, singingSoon: Float) {
        let current = words.indices.filter { words[$0].line == lineIndex && words[$0].popAt == .infinity }
        guard !current.isEmpty else { return }
        if !wordByWord, let started = lineShownAt {
            // Line by line: once the line has started, the rest of it follows straight away.
            let stagger = min(0.035, 0.3 / Double(current.count))
            for (n, i) in current.enumerated() where words[i].appearAt == nil {
                let a = started + Double(n) * stagger
                guard lt >= a else { break }
                words[i].appearAt = a
                words[i].appearClock = clock - (lt - a)
                wordsShown += 1
                lastAppearTime = a
                onWordAppear?(words[i].line, words[i].index, a + offset - lead)
            }
            return
        }
        // Only wait on the singer once this song has shown the detector hears them clearly.
        // (Clear separation between sung lines and instrumental breaks; on dense mixes it isn't there.)
        let inLines = vocalInLines.sum / Double(max(vocalInLines.count, 1))
        let inGaps = vocalInGaps.sum / Double(max(vocalInGaps.count, 1))
        let trusted = vocalInLines.count >= 120 && vocalInGaps.count >= 60 && inLines - inGaps >= 0.25
        let listening = useVoiceOnsets && (trusted || ignoreVoiceTrust) && !holdsOffForLine
        if listening {
            if singingNow > 0.5 { lastSinging = lt }
            if let start = pendingOnsets.last(where: { $0 <= lt + 0.001 }) { lastPhraseStart = max(lastPhraseStart, start) }
        }
        if listening {
            if singingNow > 0.5 {
                singingState = true
                quietFrom = .infinity
            } else if singingNow < 0.3 {
                if quietFrom == .infinity { quietFrom = lt }
                if singingState, lt - quietFrom > 0.2 {
                    singingState = false
                    if lineVoiceStart != nil { lineVoiceEnd = quietFrom }
                }
            }
        }
        // Silent = nothing now, nothing a moment ago, nothing in the audio about to play.
        let silent = listening && singingSoon < 0.5 && lt - lastSinging > 0.15
        let unshown = current.filter { words[$0].appearAt == nil }.count

        var remaining = unshown
        for i in current where words[i].appearAt == nil {
            let first = !current.contains { words[$0].appearAt != nil }
            let due = words[i].guess + holdShift
            var appear: Double?
            var shift = 1.0

            // Never let a line end with words unshown: catch up, a word every 0.08 s at most.
            let deadline = lineEnd - 0.1 * Double(remaining)
            if lt >= deadline {
                if lt - lastAppearTime < 0.08 { break }
                appear = lt
            } else if lt < due {
                // Singer came in just before this line's stamp: follow them.
                // Only once the singing has carried on for a moment, so a stray sound can't trigger it.
                if listening, first, lastPhraseStart >= due - 0.3, lt - lastPhraseStart >= 0.06,
                   lastPhraseStart > lineSpawnTime, singingNow > 0.5 {
                    appear = lastPhraseStart
                }
            } else {
                let waited = lt - due
                let freshStart = listening && lastPhraseStart >= due - 0.35
                // The singer stopped with only the tail of the line left: they've probably sung it.
                let tail = Double(unshown) <= Double(current.count) * 0.34 && lt - lastSinging < 0.6
                if !silent || tail {
                    appear = waited > 0.05 ? lt : due
                } else if freshStart {
                    appear = max(lastPhraseStart, due)
                } else if waited >= (first ? 0.8 : 0.5) {
                    appear = lt
                    shift = 0.3                         // gave up waiting: the detector was probably wrong
                    holdsOffForLine = true
                }
            }
            guard let a = appear else { break }
            if a > due + 0.05 { holdShift = min(holdShift + (a - due) * shift, 2.0) }
            if a < due - 0.05 { holdShift -= due - a }
            words[i].appearAt = a
            words[i].appearClock = clock - (lt - a)
            if first { lineVoiceStart = a }
            wordsShown += 1
            remaining -= 1
            lastAppearTime = a
            onWordAppear?(words[i].line, words[i].index, a + offset - lead)
            // Line by line: the line starts when its first word would (with the singer, never
            // more than a moment late) and the rest appears on the next frames.
            if !wordByWord { lineShownAt = a; break }
        }
    }

    private func sampleVocalStats(lyrics: Lyrics, lyricTime lt: Double, singing: Float) {
        guard let next = lyrics.lines.firstIndex(where: { $0.time > lt }) else { return }
        let nextTime = lyrics.lines[next].time
        if next > 0 {
            let line = lyrics.lines[next - 1]
            let inside = lt > line.time + 0.3 && lt < min(line.time + 2.5, nextTime - 0.2) && line.text.contains(where: \.isLetter)
            if inside { vocalInLines.sum += Double(singing); vocalInLines.count += 1; return }
        }
        let gapStart = next > 0 ? lyrics.lines[next - 1].time + 4 : 3
        if lt > gapStart, lt < nextTime - 0.8 { vocalInGaps.sum += Double(singing); vocalInGaps.count += 1 }
    }

    /// The last line was sung from its first word until the singer went quiet: that's its real pace.
    private func finishLineMeasurement() {
        defer { lineVoiceStart = nil; lineVoiceEnd = nil }
        guard learnOffsets || useVoiceOnsets, let start = lineVoiceStart, let end = lineVoiceEnd,
              end - start > 0.6, lineSyllables >= 3 else { return }
        let rate = Double(lineSyllables) / (end - start)
        guard rate > 0.8, rate < 9 else { return }
        observedRates.append(rate)
        if observedRates.count > 12 { observedRates.removeFirst() }
        let sorted = observedRates.sorted()
        let median = sorted[sorted.count / 2]
        let trust = min(Double(observedRates.count) / 3, 1) * 0.8
        songRate = initialRate * (1 - trust) + median * trust
    }

    private func learn(songTime raw: Double, lyrics: Lyrics) {
        while learnCursor < lyrics.lines.count {
            let line = lyrics.lines[learnCursor]
            guard raw > line.time + (learner.estimate ?? 0) + 1.3 else { break }
            if learnOffsets, manualOffset == nil, raw - line.time < 10, line.text.contains(where: \.isLetter) {
                learner.addLine(start: line.time, onsets: onsetHistory)
            }
            learnCursor += 1
        }
    }

    // MARK: Spawning

    private func spawn(line idx: Int, in lyrics: Lyrics, aspect: Float, lyricTime lt: Double) {
        let line = lyrics.lines[idx]
        var texts = line.text.split(whereSeparator: \.isWhitespace).map(String.init)
            .filter { $0.rangeOfCharacter(from: .alphanumerics) != nil }
        guard !texts.isEmpty else { return }
        if theme.uppercase { texts = texts.map { $0.uppercased() } }

        page = (page + 1) % Self.pages
        let placed = renderPage(words: Array(texts.prefix(28)))
        guard !placed.isEmpty else { return }
        texts = Array(texts.prefix(placed.count))
        let next = idx + 1 < lyrics.lines.count ? lyrics.lines[idx + 1].time : nil
        finishLineMeasurement()
        lineSyllables = texts.reduce(0) { $0 + WordTiming.syllables($1) }
        let timing = WordTiming.guesses(words: texts, lineStart: line.time, nextLine: next, rate: songRate)
        holdShift = 0
        lineSpawnTime = lt
        holdsOffForLine = false
        lineEnd = next.map { $0 - 0.25 } ?? .infinity
        lineShownAt = nil

        let h = theme.textHeight, gap = theme.gap
        let halves: [SIMD2<Float>] = placed.map { p in
            if theme == .bubbles {
                let r = max(h * p.aspect * 0.5 + 0.012, 0.052)
                return SIMD2(r, r)
            }
            return SIMD2(h * 0.5 * p.aspect, h * 0.5)
        }

        let maxRow = min(aspect * 0.84, 1.55)
        var rows: [[Int]] = [[]]
        var width: Float = 0
        for (i, half) in halves.enumerated() {
            let w = half.x * 2 + gap
            if width + w > maxRow, !rows[rows.count - 1].isEmpty { rows.append([]); width = 0 }
            rows[rows.count - 1].append(i)
            width += w
        }
        let rowGap: Float = theme == .bubbles ? gap : h * 0.4
        let rowHeights = rows.map { row in (row.map { halves[$0].y }.max() ?? h) * 2 + rowGap }
        let blockHeight = rowHeights.reduce(0, +)
        var y = stageY - blockHeight * 0.5
        y = min(y, 0.47 - blockHeight)
        y = max(y, -0.47)

        for (r, row) in rows.enumerated() {
            let rowWidth = row.reduce(Float(0)) { $0 + halves[$1].x * 2 + gap } - gap
            var x = -rowWidth * 0.5
            y += rowHeights[r] * 0.5
            for i in row {
                x += halves[i].x
                let jitter: Float = (theme == .bubbles || theme == .stickers)
                    ? Float.random(in: -0.012...0.012, using: &rng) : 0
                let home = SIMD2(x, y + jitter)
                var word = Word(rect: placed[i].rect, aspect: placed[i].aspect, line: idx, index: i,
                                guess: timing[i].start, duration: timing[i].duration, appearAt: nil,
                                spawnClock: clock, home: home,
                                pos: theme == .bubbles ? home + SIMD2(0, 0.07) : home,
                                size: theme == .bubbles ? halves[i].x : h * 0.5,
                                seed: Float.random(in: 0...1, using: &rng),
                                rotation: theme == .stickers ? Float.random(in: -0.14...0.14, using: &rng) : 0)
                if lt > word.guess + 0.5 {                 // already sung (style switch or seek)
                    word.appearAt = word.guess
                    word.appearClock = clock - 1
                    word.pos = home
                }
                words.append(word)
                x += halves[i].x + gap
            }
            y += rowHeights[r] * 0.5
        }
    }

    /// Draws the words into the free atlas page in the theme's font.
    private func renderPage(words: [String]) -> [(rect: SIMD4<Float>, aspect: Float)] {
        let W = Self.atlasW, H = Self.pageH
        pageBuffer.update(repeating: 0, count: W * H)
        guard let ctx = CGContext(data: pageBuffer, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return [] }
        ctx.setAllowsFontSmoothing(false)
        ctx.setShouldAntialias(true)
        ctx.setFillColor(gray: 1, alpha: 1)

        let font = fonts[theme] ?? CTFontCreateWithName(theme.fontName as CFString, Self.fontPx, nil)
        fonts[theme] = font
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let lineH = ceil(ascent + descent)
        let pad: CGFloat = 24, inset: CGFloat = 18, insetY: CGFloat = 16, rowGap: CGFloat = 24
        let boxH = lineH + insetY * 2
        let baselineFromTop = theme.uppercase ? boxH / 2 + CTFontGetCapHeight(font) / 2 : insetY + ascent
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        var x = pad, top = pad
        var out: [(SIMD4<Float>, Float)] = []
        for word in words {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: word, attributes: attrs))
            let w = ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))) + inset * 2
            if x + w + pad > CGFloat(W) { x = pad; top += boxH + rowGap }
            if top + boxH + pad > CGFloat(H) { break }
            ctx.textPosition = CGPoint(x: x + inset, y: CGFloat(H) - top - baselineFromTop)
            CTLineDraw(line, ctx)
            let v0 = (CGFloat(page * H) + top) / CGFloat(H * Self.pages)
            out.append((SIMD4(Float(x / CGFloat(W)), Float(v0), Float(w / CGFloat(W)), Float(boxH / CGFloat(H * Self.pages))),
                        Float(w / boxH)))
            x += w + pad
        }
        atlas.replace(region: MTLRegionMake2D(0, page * H, W, H), mipmapLevel: 0, withBytes: pageBuffer, bytesPerRow: W)
        atlasNeedsMipmaps = true
        return out
    }
}
