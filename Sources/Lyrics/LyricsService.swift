import CryptoKit
import Foundation

struct LyricLine: Codable, Equatable {
    let time: Double      // seconds into the song
    let text: String
}

struct Lyrics: Codable, Equatable {
    let trackID: String
    let lines: [LyricLine]
    let instrumental: Bool
    var isEmpty: Bool { lines.isEmpty }
}

/// Time-synced lyrics from LRCLIB (lrclib.net) — a free, open lyrics database.
/// Only the song name, artist, album and length are sent. Results are cached on disk.
actor LyricsService {
    private let session: URLSession
    private let cacheDir: URL
    private var memory: [String: Lyrics] = [:]

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.httpAdditionalHeaders = ["User-Agent": "Aura/1.0 (macOS music visualiser; +https://github.com/JacksonYowe/aura-visualiser)"]
        session = URLSession(configuration: config)
        cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.aura.Aura/Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    func lyrics(for track: SpotifyClient.Track) async -> Lyrics? {
        guard !track.id.hasPrefix("spotify:episode"), !track.name.isEmpty else { return nil }
        if let hit = memory[track.id] { return hit }

        let file = cacheDir.appendingPathComponent(Self.hash(track.id) + ".json")
        if let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode(Lyrics.self, from: data) {
            // Re-check "not found" results after a day; real lyrics are kept.
            let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map { Date().timeIntervalSince($0) } ?? 0
            if !cached.isEmpty || cached.instrumental || age < 86_400 {
                memory[track.id] = cached
                return cached
            }
        }

        guard let found = await fetch(track) else { return nil }   // network failure: don't cache
        memory[track.id] = found
        if let data = try? JSONEncoder().encode(found) { try? data.write(to: file, options: .atomic) }
        return found
    }

    // MARK: Network

    private struct Record: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let syncedLyrics: String?
    }

    /// nil = couldn't reach LRCLIB; empty Lyrics = reached it, nothing synced.
    private func fetch(_ track: SpotifyClient.Track) async -> Lyrics? {
        let artist = Self.primaryArtist(track.artist)
        var get = URLComponents(string: "https://lrclib.net/api/get")!
        get.queryItems = [
            .init(name: "track_name", value: track.name),
            .init(name: "artist_name", value: artist),
            .init(name: "album_name", value: track.album),
            .init(name: "duration", value: String(Int(track.duration.rounded()))),
        ]
        var reachable = false
        if let (data, response) = try? await session.data(from: get.url!), let http = response as? HTTPURLResponse {
            reachable = true
            if http.statusCode == 200, let record = try? JSONDecoder().decode(Record.self, from: data) {
                if let lyrics = build(record, trackID: track.id) { return lyrics }
            }
        }

        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [
            .init(name: "track_name", value: Self.cleanTitle(track.name)),
            .init(name: "artist_name", value: artist),
        ]
        if let (data, response) = try? await session.data(from: search.url!),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let records = try? JSONDecoder().decode([Record].self, from: data) {
            reachable = true
            // Lyrics timed for a different edit of the song drift out of sync, so the length must match.
            let candidates = records
                .filter { ($0.syncedLyrics?.isEmpty == false) }
                .filter { track.duration <= 0 || abs(($0.duration ?? track.duration) - track.duration) <= 2 }
                .sorted { abs(($0.duration ?? 0) - track.duration) < abs(($1.duration ?? 0) - track.duration) }
            if let best = candidates.first, let lyrics = build(best, trackID: track.id) { return lyrics }
            if records.contains(where: { $0.instrumental == true }) {
                return Lyrics(trackID: track.id, lines: [], instrumental: true)
            }
        }
        return reachable ? Lyrics(trackID: track.id, lines: [], instrumental: false) : nil
    }

    private func build(_ record: Record, trackID: String) -> Lyrics? {
        if record.instrumental == true { return Lyrics(trackID: trackID, lines: [], instrumental: true) }
        guard let synced = record.syncedLyrics, !synced.isEmpty else { return nil }
        let lines = LRCParser.parse(synced)
        return lines.isEmpty ? nil : Lyrics(trackID: trackID, lines: lines, instrumental: false)
    }

    // MARK: Helpers

    static func primaryArtist(_ s: String) -> String {
        var a = s
        for sep in [", ", " & ", " feat. ", " ft. ", " x "] {
            if let r = a.range(of: sep, options: .caseInsensitive) { a = String(a[..<r.lowerBound]) }
        }
        return a
    }

    /// "Song - 2013 Remaster" / "Song (feat. X)" → "Song"
    static func cleanTitle(_ s: String) -> String {
        var t = s
        if let r = t.range(of: " - ") { t = String(t[..<r.lowerBound]) }
        if let r = t.range(of: " (feat", options: .caseInsensitive) { t = String(t[..<r.lowerBound]) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum LRCParser {
    /// Parses "[mm:ss.xx] text" lines (multiple stamps per line and [offset:±ms] supported).
    static func parse(_ lrc: String) -> [LyricLine] {
        var offset = 0.0
        var out: [LyricLine] = []
        for raw in lrc.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            var stamps: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
                if tag.lowercased().hasPrefix("offset:") {
                    let ms = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) ?? 0
                    offset = ms.isFinite && abs(ms) < 60_000 ? ms / 1000 : 0
                    continue
                }
                let parts = tag.split(separator: ":")
                // Public database: only take plain, sane numbers (no inf, nan or wild values).
                guard parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]),
                      m.isFinite, s.isFinite, m >= 0, m < 1000, s >= 0, s < 100 else { continue }
                stamps.append(m * 60 + s)
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for t in stamps { out.append(LyricLine(time: t, text: text)) }
        }
        return out.map { LyricLine(time: max(0, $0.time - offset), text: $0.text) }.sorted { $0.time < $1.time }
    }
}
