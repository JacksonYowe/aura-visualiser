import AppKit
import Observation
import SwiftUI

enum AutoChange: String, CaseIterable, Identifiable {
    case off, eachSong, timed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Off"
        case .eachSong: "Each song"
        case .timed: "Every 30s"
        }
    }
}

enum LyricsStatus: Equatable { case none, loading, synced(Int), notFound, instrumental }

/// Everything the window shows, plus the glue between Spotify, the audio tap and the renderer.
@Observable
final class AppModel {
    // Playback
    private(set) var nowPlaying = SpotifyClient.NowPlaying()
    private(set) var coverImage: NSImage?
    private(set) var spotifyAccess: SpotifyClient.Access = .unknown
    private(set) var tapStatus: AudioTap.Status = .stopped
    private(set) var hearingAudio = false
    private(set) var silentWhilePlaying: Double = 0
    private(set) var lyricsStatus: LyricsStatus = .none

    // UI state
    var hudVisible = true { didSet { renderer?.setHUDVisible(hudVisible) } }
    private(set) var titleCardTrack: SpotifyClient.Track?
    var settingsOpen = false

    // Settings (persisted)
    var mode: VisualMode = .halo {
        didSet { renderer?.setMode(mode); defaults.set(mode.rawValue, forKey: "mode"); lastAutoChange = Date() }
    }
    var sensitivity: Double = 1.0 {
        didSet { renderer?.setSensitivity(Float(sensitivity)); defaults.set(sensitivity, forKey: "sensitivity") }
    }
    var syncOffsetMs: Double = 0 {
        didSet { renderer?.setSyncOffset(syncOffsetMs / 1000); defaults.set(syncOffsetMs, forKey: "syncOffsetMs") }
    }
    var autoChange: AutoChange = .off {
        didSet { defaults.set(autoChange.rawValue, forKey: "autoChange"); lastAutoChange = Date() }
    }
    var source: AudioTap.Source = .spotify {
        didSet { tap.preferredSource = source; defaults.set(source.rawValue, forKey: "source") }
    }
    var showTitleOnChange = true {
        didSet { defaults.set(showTitleOnChange, forKey: "showTitleOnChange") }
    }
    var showLyrics = true {
        didSet { renderer?.setLyricsEnabled(showLyrics); defaults.set(showLyrics, forKey: "showLyrics") }
    }
    var lookAhead = true {
        didSet { tap.lookAheadEnabled = lookAhead; defaults.set(lookAhead, forKey: "lookAhead") }
    }
    var ringSettings = RingSettings() {
        didSet {
            guard ringSettings != oldValue else { return }
            renderer?.setRingSettings(ringSettings)
            if let data = try? JSONEncoder().encode(ringSettings) { defaults.set(data, forKey: "ringSettings") }
            updateGenreDetection()
        }
    }
    /// The genre Aura heard in this song (only used when rings are set to "Detect genre").
    private(set) var detectedGenre: RingSettings.Genre?
    @ObservationIgnored private let genreDetector = GenreDetector()
    var ringMeter: Renderer.RingMeter { renderer?.ringMeter ?? .init() }
    var lyricTheme: LyricTheme = .bubbles {
        didSet { renderer?.setLyricTheme(lyricTheme); defaults.set(lyricTheme.rawValue, forKey: "lyricTheme") }
    }
    /// Off = whole lines appear at once (default); on = each word as it's sung (experimental).
    var lyricsWordByWord = false {
        didSet { renderer?.setLyricsWordByWord(lyricsWordByWord); defaults.set(lyricsWordByWord, forKey: "lyricsWordByWord") }
    }

    // Lyric timing
    /// This song's manual shift in seconds (positive = later), or nil when Aura times it automatically.
    private(set) var lyricNudge: Double?
    /// What Aura has learned about this song's timing so far (for the settings label).
    private(set) var lyricLearned: Double?
    private(set) var toast: String?

    let renderer: Renderer?
    @ObservationIgnored let tap = AudioTap()
    @ObservationIgnored let spotify = SpotifyClient()
    @ObservationIgnored private let artwork = ArtworkLoader()
    @ObservationIgnored private let lyricsService = LyricsService()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var clock = PlaybackClock()
    @ObservationIgnored private var lastActivity = Date()
    @ObservationIgnored private var lastAutoChange = Date()
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var titleCardTask: Task<Void, Never>?
    @ObservationIgnored private var artTask: Task<Void, Never>?
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    @ObservationIgnored private var loadingArtKey = ""
    @ObservationIgnored private var artworkKey = ""
    @ObservationIgnored private var lastCallbackCount = 0
    @ObservationIgnored private var deadTapTime: Double = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var lastLoggedCount = 0
    @ObservationIgnored private var trackSeenAt = Date.distantPast
    @ObservationIgnored private var captureSignal: DispatchSourceSignal?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init() {
        renderer = Renderer()
        if let m = VisualMode(rawValue: defaults.integer(forKey: "mode")) { mode = m }
        if defaults.object(forKey: "sensitivity") != nil { sensitivity = defaults.double(forKey: "sensitivity") }
        syncOffsetMs = defaults.double(forKey: "syncOffsetMs")
        autoChange = AutoChange(rawValue: defaults.string(forKey: "autoChange") ?? "") ?? .off
        source = AudioTap.Source(rawValue: defaults.string(forKey: "source") ?? "") ?? .spotify
        if defaults.object(forKey: "showTitleOnChange") != nil { showTitleOnChange = defaults.bool(forKey: "showTitleOnChange") }
        if defaults.object(forKey: "showLyrics") != nil { showLyrics = defaults.bool(forKey: "showLyrics") }
        if defaults.object(forKey: "lookAhead") != nil { lookAhead = defaults.bool(forKey: "lookAhead") }
        lyricTheme = LyricTheme(rawValue: defaults.integer(forKey: "lyricTheme")) ?? .bubbles
        lyricsWordByWord = defaults.bool(forKey: "lyricsWordByWord")
        if let data = defaults.data(forKey: "ringSettings"), let saved = try? JSONDecoder().decode(RingSettings.self, from: data) {
            ringSettings = saved
        }
        renderer?.setMode(mode)
        renderer?.setSensitivity(Float(sensitivity))
        renderer?.setSyncOffset(syncOffsetMs / 1000)
        renderer?.setLyricsEnabled(showLyrics)
        renderer?.setLyricTheme(lyricTheme)
        renderer?.setLyricsWordByWord(lyricsWordByWord)
        renderer?.setRingSettings(ringSettings)
    }

    func start() {
        guard !started else { return }
        started = true
        renderer?.feed = tap

        DiagnosticsLog.write("Aura started · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        genreDetector.rhythm = { [weak self] in
            let f = self?.renderer?.stats.features ?? AudioAnalyzer.Features()
            return .init(bpm: f.bpm, locked: f.tempoLock > 0.5, kickOnBeat: f.kickOnBeat, lowShare: f.lowShare, energy: f.energy)
        }
        genreDetector.onResult = { [weak self] genre, summary in
            guard let self else { return }
            if self.detectedGenre != genre {
                DiagnosticsLog.write("genre → \(genre.title) · \(summary)")
                self.detectedGenre = genre
                self.renderer?.setDetectedGenre(genre)
            }
        }
        tap.onStatus = { [weak self] status in
            self?.tapStatus = status
            self?.updateGenreDetection()
            DiagnosticsLog.write("audio tap → \(status) · output latency \(Int((self?.tap.outputLatency ?? 0) * 1000)) ms")
        }
        tap.preferredSource = source
        tap.lookAheadEnabled = lookAhead
        tap.start()

        spotify.onAccess = { [weak self] access in
            self?.spotifyAccess = access
            DiagnosticsLog.write("spotify access → \(access)")
        }
        spotify.onUpdate = { [weak self] in self?.apply($0, fromBroadcast: false) }
        spotify.onBroadcast = { [weak self] in self?.apply($0, fromBroadcast: true) }
        spotify.start()

        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }

        // Dev aid: `kill -USR1 <pid>` saves the next frame to ~/Library/Logs/Aura/capture.png.
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in self?.renderer?.requestCapture() }
        source.resume()
        captureSignal = source
    }

    func stop() {
        DiagnosticsLog.write("Aura quitting")
        tap.stop()
    }

    // MARK: Now playing

    var position: Double { clock.position(at: CACurrentMediaTime()) }

    private func apply(_ incoming: SpotifyClient.NowPlaying, fromBroadcast: Bool) {
        var merged = incoming
        if fromBroadcast, let id = merged.track?.id, id == nowPlaying.track?.id {
            merged.track?.artworkURL = nowPlaying.track?.artworkURL ?? ""
        }
        let previousID = nowPlaying.track?.id
        if merged != nowPlaying { nowPlaying = merged }
        updateClock(merged)

        guard let track = merged.track else {
            if previousID != nil || artworkKey.isEmpty {
                artworkKey = "placeholder"
                renderer?.setArtwork(nil, palette: nil)
                coverImage = nil
                renderer?.setLyrics(nil)
                lyricsStatus = .none
            }
            return
        }
        if track.id != previousID { trackChanged(track, hadPrevious: previousID != nil) }
        loadArtworkIfNeeded(track)
    }

    /// Smooths Spotify's once-a-second position reports into a steady clock (snaps on seeks).
    private func updateClock(_ now: SpotifyClient.NowPlaying) {
        let t = now.positionTime > 0 ? now.positionTime : CACurrentMediaTime()
        let id = now.track?.id ?? ""
        let playing = now.state == .playing
        var next = PlaybackClock(trackID: id, position: now.position, hostTime: t, playing: playing)
        if clock.trackID == id, clock.playing, playing {
            let predicted = clock.position(at: t)
            let error = now.position - predicted
            if abs(error) < 0.35 { next.position = predicted + error * 0.2 }
        }
        clock = next
        renderer?.setPlayback(next)
    }

    private func updateGenreDetection() {
        guard started else { return }
        if ringSettings.mode == .genre, ringSettings.genre == .auto, case .listening = tapStatus {
            genreDetector.start(ring: tap.ring, sampleRate: tap.sampleRate)
        } else {
            genreDetector.stop()
        }
    }

    private func trackChanged(_ track: SpotifyClient.Track, hadPrevious: Bool) {
        genreDetector.reset()      // keeps using the last genre until this song is identified
        renderer?.trackChanged()
        DiagnosticsLog.write("track → \(track.name) — \(track.artist) [\(track.id)]")
        trackSeenAt = Date()
        if hadPrevious, autoChange == .eachSong { mode = mode.next(1) }
        loadLyrics(track)
        guard showTitleOnChange, !track.name.isEmpty else { return }
        titleCardTask?.cancel()
        withAnimation(Tokens.ease) { titleCardTrack = track }
        titleCardTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.9)) { self?.titleCardTrack = nil }
        }
    }

    private func loadLyrics(_ track: SpotifyClient.Track) {
        lyricsTask?.cancel()
        renderer?.setLyrics(nil)
        lyricNudge = nil
        lyricLearned = nil
        lyricsStatus = .loading
        lyricsTask = Task { [weak self, lyricsService] in
            let result = await lyricsService.lyrics(for: track)
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled, self.nowPlaying.track?.id == track.id else { return }
                if let result, !result.isEmpty {
                    DiagnosticsLog.write(String(format: "lyric timing start: prior %+.2f s, this song learned %@, nudged %@",
                                                self.priorOffset,
                                                self.learnedOffsets[track.id].map { String(format: "%+.2f", $0) } ?? "-",
                                                self.manualOffsets[track.id].map { String(format: "%+.2f", $0) } ?? "-"))
                    self.lyricNudge = self.manualOffsets[track.id]
                    self.lyricLearned = self.learnedOffsets[track.id]
                    self.renderer?.setLyrics(result, manualOffset: self.lyricNudge,
                                             learnedOffset: self.learnedOffsets[track.id], priorOffset: self.priorOffset)
                    self.lyricsStatus = .synced(result.lines.count)
                } else {
                    self.lyricsStatus = result?.instrumental == true ? .instrumental : .notFound
                }
                DiagnosticsLog.write("lyrics → \(self.lyricsStatus)")
            }
        }
    }

    private func loadArtworkIfNeeded(_ track: SpotifyClient.Track) {
        // Wait briefly for the Apple Event refresh to supply the artwork URL before using the web fallback.
        let key = track.artworkURL.isEmpty ? "oembed:\(track.id)" : track.artworkURL
        guard key != loadingArtKey else { return }
        if track.artworkURL.isEmpty, Date().timeIntervalSince(trackSeenAt) < 1.5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self, let t = self.nowPlaying.track, t.id == track.id, t.artworkURL.isEmpty else { return }
                self.loadArtworkIfNeeded(t)
            }
            if !loadingArtKey.hasPrefix("wait:") { loadingArtKey = "wait:\(track.id)" }
            return
        }
        loadingArtKey = key
        artTask?.cancel()
        artTask = Task { [weak self, artwork] in
            let result = await artwork.load(track: track)
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled, self.nowPlaying.track?.id == track.id else { return }
                DiagnosticsLog.write(result != nil ? "artwork loaded (\(result!.image.width)px)" : "artwork unavailable for \(track.id)")
                if let result {
                    self.artworkKey = result.key
                    self.renderer?.setArtwork(result.image, palette: result.palette)
                    self.coverImage = NSImage(cgImage: result.image, size: NSSize(width: result.image.width, height: result.image.height))
                } else {
                    self.artworkKey = "placeholder:\(track.id)"
                    self.renderer?.setArtwork(nil, palette: nil)
                    self.coverImage = nil
                }
            }
        }
    }

    // MARK: Lyric timing + styles

    private var manualOffsets: [String: Double] {
        get { defaults.dictionary(forKey: "lyricManualOffsets") as? [String: Double] ?? [:] }
        set { defaults.set(newValue, forKey: "lyricManualOffsets") }
    }
    private var learnedOffsets: [String: Double] {
        get { defaults.dictionary(forKey: "lyricLearnedOffsets") as? [String: Double] ?? [:] }
        set { defaults.set(newValue, forKey: "lyricLearnedOffsets") }
    }

    /// Where a song's lyric timing starts before Aura knows anything about it. Real lyric files
    /// (and Spotify's reported position) run early — one clearly-heard song measured +0.49 s — so
    /// the default is 0.3 s later. Every song Aura measures, and every song you nudge with [ ],
    /// pulls this towards your setup.
    private var priorOffset: Double {
        let fallback = 0.3, weight = 2.0
        let values = (Array(learnedOffsets.values) + Array(manualOffsets.values)).sorted()
        guard !values.isEmpty else { return fallback }
        let median = values[values.count / 2]
        let blended = (fallback * weight + median * Double(values.count)) / (weight + Double(values.count))
        return max(-0.3, min(0.9, blended))
    }

    private func saveLearnedOffset(_ stats: Renderer.Stats) {
        guard let id = nowPlaying.track?.id, stats.lyricTrack == id else { return }
        if lyricLearned != stats.lyricLearned { lyricLearned = stats.lyricLearned }
        guard let learned = stats.lyricLearned, stats.lyricSamples >= 8 else { return }
        var all = learnedOffsets
        guard all[id] != learned else { return }
        all[id] = learned
        if all.count > 400 { all.removeValue(forKey: all.keys.first!) }
        learnedOffsets = all
    }

    /// Positive = show lyrics later.
    func nudgeLyrics(_ delta: Double) {
        guard let id = nowPlaying.track?.id, case .synced = lyricsStatus else {
            showToast("No timed lyrics for this song")
            return
        }
        renderer?.nudgeLyrics(by: delta) { [weak self] value in
            guard let self else { return }
            self.lyricNudge = value
            var all = self.manualOffsets
            all[id] = value
            self.manualOffsets = all
            self.showToast(String(format: "Lyrics %@ · %+.2f s for this song", delta > 0 ? "later" : "earlier", value))
        }
    }

    func resetLyricTiming() {
        guard let id = nowPlaying.track?.id else { return }
        renderer?.clearLyricNudge()
        lyricNudge = nil
        var all = manualOffsets
        all.removeValue(forKey: id)
        manualOffsets = all
        showToast("Lyric timing · automatic")
    }

    func cycleLyricTheme() {
        let all = LyricTheme.allCases
        lyricTheme = all[(lyricTheme.rawValue + 1) % all.count]
        if !showLyrics { showLyrics = true }
        showToast("Lyrics · \(lyricTheme.title)")
    }

    func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation(Tokens.ease) { toast = text }
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.5)) { self?.toast = nil }
        }
    }

    // MARK: Controls

    func playPause() { spotify.playPause() }
    func nextTrack() { spotify.next() }
    func previousTrack() { spotify.previous() }

    func openSpotify() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyClient.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    func openAudioCaptureSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
    }

    // MARK: Activity / auto-hide

    func noteActivity() {
        lastActivity = Date()
        if !hudVisible { withAnimation(Tokens.ease) { hudVisible = true } }
    }

    func toggleHUD() {
        withAnimation(Tokens.ease) { hudVisible.toggle() }
        lastActivity = hudVisible ? Date() : .distantPast
    }

    private func tick() {
        let idle = Date().timeIntervalSince(lastActivity)
        if hudVisible, idle > 3.5, !settingsOpen, banner == nil {
            withAnimation(.easeInOut(duration: 0.6)) { hudVisible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        if autoChange == .timed, Date().timeIntervalSince(lastAutoChange) > 30 { mode = mode.next(1) }

        let stats = renderer?.stats
        let silent = stats?.features.silent ?? true
        if hearingAudio == silent { hearingAudio = !silent }
        if nowPlaying.state == .playing, silent { silentWhilePlaying += 0.25 } else { silentWhilePlaying = 0 }

        let count = tap.callbackCount.load(ordering: .relaxed)
        tickCount += 1
        if tickCount % 12 == 0, let stats {
            let f = stats.features
            let inOff = Double(bitPattern: tap.diagInputOffset.load(ordering: .relaxed)) * 1000
            let outOff = Double(bitPattern: tap.diagOutputOffset.load(ordering: .relaxed)) * 1000
            let peak = Double(bitPattern: tap.diagOutputPeak.load(ordering: .relaxed))
            DiagnosticsLog.write(String(format: "status · %@ cb=%d · fps=%.0f slow=%d gpu=%.1fms scale=%.2f present=+%.0fms · lookahead=%.0fms in=%+.1fms out=%+.1fms outPeak=%.2f · beats=%d rings=%d bpm=%.0f lock=%.2f energy=%.2f silent=%@ · lyrics %@ items=%d offset=%+.2fs learned=%@ (%d lines) manual=%@ pace=%.2f singing lines/gaps=%@ words shown/skipped=%d/%d · %@ “%@”",
                                        "\(tapStatus)", count - lastLoggedCount, stats.fps, stats.slowFrames, stats.gpuMs, stats.scale, stats.presentMs,
                                        f.lookAhead * 1000, inOff, outOff, peak,
                                        f.beatCount, f.ringsLaunched, f.bpm, f.tempoLock, f.energy, f.silent ? "yes" : "no",
                                        lyricTheme.title, stats.bubbles, stats.lyricOffset,
                                        stats.lyricLearned.map { String(format: "%+.2fs", $0) } ?? "-", stats.lyricSamples,
                                        stats.lyricManual.map { String(format: "%+.2fs", $0) } ?? "-",
                                        stats.songRate,
                                        stats.vocalLines >= 0 ? String(format: "%.2f/%@", stats.vocalLines, stats.vocalGaps >= 0 ? String(format: "%.2f", stats.vocalGaps) : "-") : "-",
                                        stats.wordsShown, stats.wordsSkipped,
                                        "\(nowPlaying.state)", nowPlaying.track?.name ?? "-"))
            lastLoggedCount = count
            saveLearnedOffset(stats)
        }
        // Core Audio only cycles a tap while the tapped app makes sound, so only judge while playing.
        if case .listening = tapStatus, nowPlaying.state == .playing, count == lastCallbackCount {
            deadTapTime += 0.25
            if deadTapTime > 6 {
                deadTapTime = 0
                DiagnosticsLog.write("no audio callbacks for 6s while playing — rebuilding tap")
                tap.scheduleRebuild(force: true)
            }
        } else {
            deadTapTime = 0
        }
        lastCallbackCount = count
    }

    /// Fills the model with sample data (used only by the --snapshot preview renderer).
    func loadPreview(track: SpotifyClient.Track, cover: CGImage) {
        nowPlaying = .init(state: .playing, position: 83, track: track)
        clock = PlaybackClock(trackID: track.id, position: 83, hostTime: CACurrentMediaTime(), playing: true)
        spotifyAccess = .granted
        tapStatus = .listening(spotify: true, lookAheadMs: 40)
        hearingAudio = true
        lyricsStatus = .synced(42)
        coverImage = NSImage(cgImage: cover, size: NSSize(width: cover.width, height: cover.height))
    }

    /// The one thing (if any) the user needs to do for Aura to work.
    var banner: Banner? {
        if case .failed(let message) = tapStatus {
            return Banner(title: "Aura couldn't start listening", detail: message,
                          action: .audioSettings, actionLabel: "Open Settings")
        }
        switch spotifyAccess {
        case .notRunning where source == .spotify:
            return Banner(title: "Spotify isn't open", detail: "Open it and play something — Aura picks it up automatically.",
                          action: .openSpotify, actionLabel: "Open Spotify")
        case .denied:
            return Banner(title: "Aura can't see what Spotify is playing",
                          detail: "Privacy & Security → Automation → Aura → turn on Spotify.",
                          action: .automationSettings, actionLabel: "Open Settings")
        default:
            break
        }
        if silentWhilePlaying > 6 {
            return Banner(title: "Aura can't hear Spotify yet",
                          detail: "Privacy & Security → Screen & System Audio Recording → allow Aura (System Audio Only).",
                          action: .audioSettings, actionLabel: "Open Settings")
        }
        return nil
    }
}
