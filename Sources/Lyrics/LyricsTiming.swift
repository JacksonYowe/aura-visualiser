import Foundation

/// Lyric files only say when each line starts. These helpers estimate the words in between
/// and learn when a whole song's file is early or late compared with the actual singing.
enum WordTiming {
    /// Rough English syllable count (vowel groups, silent final e). Anything else: 1 per 3 letters.
    static func syllables(_ word: String) -> Int {
        let w = word.lowercased().filter(\.isLetter)
        guard !w.isEmpty else { return 1 }
        let vowels = Set("aeiouy")
        guard w.contains(where: { vowels.contains($0) }) else { return max(1, w.count / 3) }
        var count = 0
        var previousVowel = false
        for ch in w {
            let v = vowels.contains(ch)
            if v && !previousVowel { count += 1 }
            previousVowel = v
        }
        if count > 1, w.hasSuffix("e"), !w.hasSuffix("le"), !w.hasSuffix("ee") { count -= 1 }
        return max(count, 1)
    }

    /// How fast this song is sung (syllables per second). Lines that run straight into the next
    /// one reveal the true pace; lines followed by a break only give a lower bound, so the
    /// faster end of the range is used.
    static func songRate(_ lines: [LyricLine]) -> Double {
        var rates: [Double] = []
        for (i, line) in lines.enumerated() where i + 1 < lines.count {
            let words = line.text.split(whereSeparator: \.isWhitespace)
            let syl = words.reduce(0) { $0 + syllables(String($1)) }
            guard syl >= 3 else { continue }
            rates.append(Double(syl) / max(lines[i + 1].time - line.time, 0.3))
        }
        guard rates.count >= 3 else { return 3.2 }
        rates.sort()
        return min(max(rates[Int(Double(rates.count - 1) * 0.85)] * 1.08, 1.2), 8)
    }

    /// When each word of a line is probably sung: at the song's pace, spread by syllables,
    /// and never spilling past the next line.
    static func guesses(words: [String], lineStart: Double, nextLine: Double?, rate: Double) -> [(start: Double, duration: Double)] {
        guard !words.isEmpty else { return [] }
        let syl = words.map { Double(syllables($0)) }
        let total = syl.reduce(0, +)
        let available = max((nextLine ?? lineStart + 5) - lineStart, 0.4)
        let span = max(min(available - 0.4, available * 0.92, total / rate + 0.1), 0.15)
        var t = lineStart
        return syl.map { s in
            let d = span * s / total
            defer { t += d }
            return (t, d)
        }
    }
}

/// Learns a song-wide lyric offset from where strong vocal onsets fall around each line start.
/// Random instrument onsets scatter; a real offset shows up as a tight cluster.
struct LyricOffsetLearner {
    private(set) var samples: [Double] = []
    /// Seconds to delay the lyrics by (positive = the file runs early). nil until confident.
    private(set) var estimate: Double?

    mutating func reset() { samples = []; estimate = nil }

    /// Picks the onset most likely to be the singer starting this line: strong, near the stamp,
    /// and coming after a quiet moment (phrases start after a breath; strummed chords don't pause).
    mutating func addLine(start: Double, onsets: [(time: Double, strength: Float)]) {
        var best: (score: Double, time: Double)?
        var previous = -Double.infinity
        for o in onsets {
            defer { previous = o.time }
            guard o.time >= start - 1.0, o.time <= start + 1.2, o.strength >= 0.5 else { continue }
            let pause = min(o.time - previous, 0.6) / 0.6
            let closeness = 1 - abs(o.time - start) / 1.4
            let score = Double(o.strength) * (0.5 + 0.5 * pause) * (0.3 + 0.7 * closeness)
            if best == nil || score > best!.score { best = (score, o.time) }
        }
        guard let best else { return }
        samples.append(best.time - start)
        if samples.count > 40 { samples.removeFirst() }
        update()
    }

    private mutating func update() {
        guard samples.count >= 4 else { return }
        let sorted = samples.sorted()
        var bestCount = 0, bestCenter = 0.0, j = 0
        for i in sorted.indices {
            while sorted[i] - sorted[j] > 0.2 { j += 1 }
            let count = i - j + 1
            if count > bestCount {
                bestCount = count
                bestCenter = sorted[j...i].reduce(0, +) / Double(count)
            }
        }
        guard bestCount >= 3, Double(bestCount) >= Double(sorted.count) * 0.5 else { return }
        estimate = abs(bestCenter) >= 0.12 ? max(-2, min(2, bestCenter)) : 0
    }
}
