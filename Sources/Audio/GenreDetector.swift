import AVFoundation
import SoundAnalysis

/// Guesses a song's genre for the ring presets.
///
/// macOS's built-in sound classifier (on-device, no network) says which instruments and voices
/// it hears — electric guitar, synthesizer, rapping, piano, drum kit… Aura combines that with its
/// own rhythm readings (tempo, kicks on every beat, how bass-heavy it is) to pick a genre.
final class GenreDetector: NSObject, SNResultsObserving, @unchecked Sendable {
    struct Rhythm { var bpm: Double; var locked: Bool; var kickOnBeat: Float; var lowShare: Float; var energy: Float }

    /// Main queue: (genre, instrument confidences used).
    var onResult: ((RingSettings.Genre, String) -> Void)?
    /// Called on the detector's queue to read the renderer's rhythm stats.
    var rhythm: () -> Rhythm = { Rhythm(bpm: 0, locked: false, kickOnBeat: 0, lowShare: 0, energy: 0) }

    private let queue = DispatchQueue(label: "app.aura.genre", qos: .utility)
    private var analyzer: SNAudioStreamAnalyzer?
    private var format: AVAudioFormat?
    private var ring: SampleRingBuffer?
    private var sampleRate: Double = 48_000
    private var readUpTo = 0
    private var position: AVAudioFramePosition = 0
    private var timer: DispatchSourceTimer?
    private var confidence: [String: Double] = [:]
    private var windows = 0
    private var lastGenre: RingSettings.Genre?
    private var agreeing = 0
    private var generation = 0

    private static let labels = ["electric_guitar", "guitar", "guitar_strum", "acoustic_guitar", "synthesizer",
                                 "electronic_organ", "electric_piano", "rapping", "singing", "choir_singing",
                                 "piano", "orchestra", "drum_kit", "drum", "snare_drum", "bass_drum", "bass_guitar"]

    func start(ring: SampleRingBuffer, sampleRate: Double) {
        queue.async { [self] in
            self.ring = ring
            if analyzer == nil || self.sampleRate != sampleRate {
                self.sampleRate = sampleRate
                makeAnalyzer()
            }
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 0.5, repeating: 0.5)
            t.setEventHandler { [weak self] in self?.feed() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    /// New song: forget what was heard.
    func reset() {
        queue.async { [self] in
            confidence.removeAll()
            windows = 0
            lastGenre = nil
            agreeing = 0
            generation += 1
            makeAnalyzer()
            if let ring { readUpTo = ring.totalWritten }
        }
    }

    private func makeAnalyzer() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        self.format = format
        let a = SNAudioStreamAnalyzer(format: format)
        if let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) {
            request.windowDuration = CMTime(seconds: 3, preferredTimescale: 48_000)
            request.overlapFactor = 0.5
            try? a.add(request, withObserver: self)
        }
        analyzer = a
        position = 0
    }

    private func feed() {
        guard let ring, let analyzer else { return }
        let newest = ring.totalWritten
        if newest - readUpTo > Int(sampleRate * 4) { readUpTo = newest - Int(sampleRate) }
        let count = newest - readUpTo
        guard count > 0, let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let data = buffer.floatChannelData?[0] else { return }
        ring.read(into: data, count: count, endingAt: newest)
        readUpTo = newest
        buffer.frameLength = AVAudioFrameCount(count)

        var sum: Float = 0
        for i in stride(from: 0, to: count, by: 8) { sum += data[i] * data[i] }
        guard sqrt(sum / Float(max(count / 8, 1))) > 0.003 else { return }   // skip silence
        analyzer.analyze(buffer, atAudioFramePosition: position)
        position += AVAudioFramePosition(count)
    }

    // MARK: SNResultsObserving (called on the analysis queue)

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        queue.async { [self] in
            for label in Self.labels {
                let c = result.classification(forIdentifier: label)?.confidence ?? 0
                confidence[label, default: 0] += c
            }
            windows += 1
            if windows >= 6, windows % 2 == 0 { decide(generation: generation) }
        }
    }

    private func decide(generation g: Int) {
        func c(_ label: String) -> Double { (confidence[label] ?? 0) / Double(max(windows, 1)) }
        let r = rhythm()
        let guitar = c("electric_guitar") + 0.5 * c("guitar") + 0.3 * c("guitar_strum")
        let synth = c("synthesizer") + 0.5 * c("electronic_organ")
        let rap = c("rapping")
        let sing = max(c("singing"), c("choir_singing"))
        let acoustic = max(c("acoustic_guitar"), c("piano"), c("orchestra"))
        let drums = max(c("drum_kit"), c("drum"), c("snare_drum"), c("bass_drum"))
        let fourOnFloor = Double(r.locked ? r.kickOnBeat : 0)
        let bpm = r.bpm
        let inRange = { (lo: Double, hi: Double) in bpm >= lo && bpm <= hi }

        var scores: [RingSettings.Genre: Double] = [:]
        scores[.electronic] = 1.2 * synth + 1.1 * fourOnFloor + (inRange(115, 140) ? 0.35 : 0) - 0.9 * guitar - 0.4 * rap
        scores[.drumAndBass] = 0.5 * synth + 0.4 * drums + (inRange(160, 185) || inRange(80, 92) ? 0.7 : 0) - 0.6 * guitar - 0.5 * fourOnFloor
        scores[.hipHop] = 1.8 * rap + 0.8 * Double(min(r.lowShare, 1)) + (inRange(60, 105) || inRange(130, 160) ? 0.2 : 0) - 0.6 * guitar
        scores[.rock] = 1.7 * guitar + 0.4 * drums - 0.5 * synth - 0.5 * rap
        scores[.pop] = 0.35 + 0.5 * sing + 0.2 * synth + 0.2 * drums - 0.3 * guitar
        scores[.chill] = (r.energy < 0.35 ? 0.45 : 0) + (bpm > 0 && bpm < 100 ? 0.2 : 0) + 0.4 * c("electric_piano") - 0.5 * drums - 0.4 * guitar
        scores[.acoustic] = 1.4 * acoustic + (drums < 0.15 ? 0.35 : 0) - 0.7 * synth - 0.6 * c("electric_guitar")

        guard let best = scores.max(by: { $0.value < $1.value })?.key else { return }
        agreeing = best == lastGenre ? agreeing + 1 : 1
        lastGenre = best
        guard agreeing >= 2 || windows == 6 else { return }

        let summary = String(format: "guitar %.2f synth %.2f rap %.2f sing %.2f acoustic %.2f drums %.2f · bpm %.0f kicks-on-beat %.2f low %.2f",
                             guitar, synth, rap, sing, acoustic, drums, bpm, fourOnFloor, r.lowShare)
        guard g == generation else { return }
        DispatchQueue.main.async { [weak self] in self?.onResult?(best, summary) }
    }
}
