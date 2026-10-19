import Foundation

/// When ring pulses fire and how they look. Saved as JSON in UserDefaults.
///
/// Two ways to set them up:
/// - **Genre** (default): pick a genre, or let Aura detect it per song. Each genre has triggers
///   tuned for how that music hits (four-on-the-floor kicks, snare backbeats, big swells…).
/// - **Expert**: build your own list of triggers — each listens to a frequency range with its
///   own loudness and sudden-change thresholds — and they all fire rings.
struct RingSettings: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case genre, expert
        var id: String { rawValue }
    }

    enum Genre: String, Codable, CaseIterable, Identifiable {
        case auto, electronic, drumAndBass, hipHop, rock, pop, chill, acoustic
        var id: String { rawValue }

        var title: String {
            switch self {
            case .auto: "Detect genre"
            case .electronic: "Techno & EDM"
            case .drumAndBass: "Drum & bass"
            case .hipHop: "Hip-hop & trap"
            case .rock: "Rock & metal"
            case .pop: "Pop"
            case .chill: "Chill & lo-fi"
            case .acoustic: "Acoustic & classical"
            }
        }

        var blurb: String {
            switch self {
            case .auto: "Aura listens to each song and picks the closest genre."
            case .electronic: "A ring on every kick."
            case .drumAndBass: "Rings on fast kicks and snares."
            case .hipHop: "Rings on 808 kicks and snares or claps."
            case .rock: "Rings on kick and snare hits."
            case .pop: "Rings on kicks and claps or snares."
            case .chill: "Softer, more spaced-out rings on the kick."
            case .acoustic: "Rings only on big, sudden swells."
            }
        }

        /// Triggers tuned for this genre.
        var preset: Triggers {
            switch self {
            case .auto, .pop:
                Triggers(rules: [Rule(source: .kick, loudness: 0.5, jump: 0.7),
                                 Rule(source: .snare, loudness: 0.55, jump: 0.75)],
                         alsoOnBeats: false, minGap: 0.12)
            case .electronic:
                Triggers(rules: [Rule(source: .kick, loudness: 0.45, jump: 0.7)], alsoOnBeats: false, minGap: 0.1)
            case .drumAndBass:
                Triggers(rules: [Rule(source: .kick, loudness: 0.45, jump: 0.7),
                                 Rule(source: .snare, loudness: 0.5, jump: 0.7)],
                         alsoOnBeats: false, minGap: 0.09)
            case .hipHop:
                Triggers(rules: [Rule(source: .sub, loudness: 0.5, jump: 0.7),
                                 Rule(source: .snare, loudness: 0.55, jump: 0.75)],
                         alsoOnBeats: false, minGap: 0.12)
            case .rock:
                Triggers(rules: [Rule(source: .kick, loudness: 0.45, jump: 0.7),
                                 Rule(source: .snare, loudness: 0.5, jump: 0.7)],
                         alsoOnBeats: false, minGap: 0.1)
            case .chill:
                Triggers(rules: [Rule(source: .kick, loudness: 0.45, jump: 0.7)], alsoOnBeats: false, minGap: 0.25)
            case .acoustic:
                Triggers(rules: [Rule(source: .everything, loudness: 0.65, jump: 0.8)], alsoOnBeats: false, minGap: 0.35)
            }
        }
    }

    /// How often rings fire on the genre page (the slider, fewest → most).
    enum Frequency: Int, Codable, CaseIterable, Identifiable {
        case bars, halfBars, beats, hits, more
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .bars: "Every bar"
            case .halfBars: "Every 2 beats"
            case .beats: "Every beat"
            case .hits: "Every hit"
            case .more: "Every hit, plus softer ones"
            }
        }

        var blurb: String {
            switch self {
            case .bars: "One ring at the start of each bar (every 4 beats), locked to the song's tempo."
            case .halfBars: "A ring on every second beat, locked to the song's tempo."
            case .beats: "A ring on every beat, locked to the song's tempo."
            case .hits: "A ring on each drum hit this genre is built on."
            case .more: "Also rings on quieter hits, so busy songs get lots of rings."
            }
        }

        /// Beats between rings for the tempo-locked settings.
        var beatsPerRing: Int? {
            switch self {
            case .bars: 4
            case .halfBars: 2
            case .beats: 1
            case .hits, .more: nil
            }
        }
    }

    enum Source: String, Codable, CaseIterable, Identifiable {
        case sub, kick, bass, snare, vocals, cymbals, everything, custom
        var id: String { rawValue }

        var title: String {
            switch self {
            case .sub: "808 & sub-bass"
            case .kick: "Kick drum"
            case .bass: "Bass"
            case .snare: "Snare & claps"
            case .vocals: "Vocals"
            case .cymbals: "Cymbals & hi-hats"
            case .everything: "Whole song"
            case .custom: "Custom range"
            }
        }

        var range: ClosedRange<Double>? {
            switch self {
            case .custom: nil
            case .sub: 30...90
            case .kick: 40...120
            case .bass: 60...250
            case .snare: 1_500...5_000
            case .vocals: 300...3_400
            case .cymbals: 6_000...16_000
            case .everything: 20...20_000
            }
        }

        var examples: String {
            switch self {
            case .sub: "Deep 808s and sub-bass drops."
            case .kick: "The thump of kick drums."
            case .bass: "Bass guitar, synth bass, low piano."
            case .snare: "Snare cracks, claps, rimshots."
            case .vocals: "Singing and rapping (and anything else in the middle of the mix)."
            case .cymbals: "Hi-hats, cymbals, shakers."
            case .everything: "Any sudden loud moment — drops, hits, swells."
            case .custom: "Your own range, set with the sliders."
            }
        }
    }

    /// One thing that fires rings.
    struct Rule: Codable, Equatable, Identifiable {
        var id = UUID()
        var source: Source = .kick
        var customLow: Double = 80
        var customHigh: Double = 250
        /// How loud the sound must be: share of the song's quiet → loud range (0…1).
        var loudness: Double = 0.55
        /// How sharply it must rise, compared with the biggest rises in this range lately (0…1).
        var jump: Double = 0.7
        var enabled = true

        var range: ClosedRange<Double> {
            source.range ?? min(customLow, customHigh - 10)...max(customHigh, customLow + 10)
        }
    }

    struct Triggers: Equatable {
        var rules: [Rule]
        var alsoOnBeats: Bool
        var minGap: Double
        /// Set: one ring every this many beats on the tempo grid (the triggers are only a fallback
        /// while there's no steady tempo).
        var beatsPerRing: Int? = nil
    }

    enum Colour: String, Codable, CaseIterable, Identifiable {
        case cover, coverMain, white, rainbow
        var id: String { rawValue }
        var title: String {
            switch self {
            case .cover: "Cover accent"
            case .coverMain: "Cover main colour"
            case .white: "White"
            case .rainbow: "Rainbow"
            }
        }
        var shaderValue: Float {
            switch self {
            case .cover: 0
            case .coverMain: 1
            case .white: 2
            case .rainbow: 3
            }
        }
    }

    var mode: Mode = .genre
    var genre: Genre = .auto
    var frequency: Frequency = .hits

    // Expert triggers
    var rules: [Rule] = [Rule(source: .kick, loudness: 0.5, jump: 0.7), Rule(source: .snare, loudness: 0.55, jump: 0.75)]
    var alsoOnBeats = false
    var minGap: Double = 0.12
    var louderIsStronger = true
    var maxRings = 8

    // Look
    var lifetime: Double = 1.1
    var thickness: Double = 1
    var brightness: Double = 1
    var colour: Colour = .cover

    /// The triggers actually in use, given the genre Aura detected for this song.
    func triggers(detected: Genre?) -> Triggers {
        switch mode {
        case .expert:
            return Triggers(rules: rules.filter(\.enabled), alsoOnBeats: alsoOnBeats, minGap: minGap)
        case .genre:
            var t = (genre == .auto ? (detected ?? .pop) : genre).preset
            switch frequency {
            case .bars, .halfBars, .beats:
                t.beatsPerRing = frequency.beatsPerRing
            case .hits:
                break
            case .more:
                t.rules = t.rules.map { rule in
                    var r = rule
                    r.loudness = max(0.15, r.loudness - 0.15)
                    r.jump = max(0.3, r.jump * 0.72)
                    return r
                }
                t.minGap *= 0.75
            }
            return t
        }
    }

    init() {}

    // Tolerate settings saved by older builds: anything missing falls back to the default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RingSettings()
        mode = (try? c.decode(Mode.self, forKey: .mode)) ?? d.mode
        genre = (try? c.decode(Genre.self, forKey: .genre)) ?? d.genre
        frequency = (try? c.decode(Frequency.self, forKey: .frequency)) ?? d.frequency
        rules = (try? c.decode([Rule].self, forKey: .rules)) ?? d.rules
        alsoOnBeats = (try? c.decode(Bool.self, forKey: .alsoOnBeats)) ?? d.alsoOnBeats
        minGap = (try? c.decode(Double.self, forKey: .minGap)) ?? d.minGap
        louderIsStronger = (try? c.decode(Bool.self, forKey: .louderIsStronger)) ?? d.louderIsStronger
        maxRings = (try? c.decode(Int.self, forKey: .maxRings)) ?? d.maxRings
        lifetime = (try? c.decode(Double.self, forKey: .lifetime)) ?? d.lifetime
        thickness = (try? c.decode(Double.self, forKey: .thickness)) ?? d.thickness
        brightness = (try? c.decode(Double.self, forKey: .brightness)) ?? d.brightness
        colour = (try? c.decode(Colour.self, forKey: .colour)) ?? d.colour
    }
}

extension RingSettings.Rule {
    init(source: RingSettings.Source, loudness: Double, jump: Double) {
        self.init()
        self.source = source
        self.loudness = loudness
        self.jump = jump
    }
}

extension ClosedRange where Bound == Double {
    /// "40–120 Hz", "1.5–5 kHz", "300 Hz – 3.4 kHz"
    var hzLabel: String {
        func k(_ hz: Double) -> String {
            let v = hz / 1000
            return v.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(v))" : String(format: "%.1f", v)
        }
        if upperBound < 1000 { return "\(Int(lowerBound.rounded()))–\(Int(upperBound.rounded())) Hz" }
        if lowerBound >= 1000 { return "\(k(lowerBound))–\(k(upperBound)) kHz" }
        return "\(Int(lowerBound.rounded())) Hz – \(k(upperBound)) kHz"
    }
}
