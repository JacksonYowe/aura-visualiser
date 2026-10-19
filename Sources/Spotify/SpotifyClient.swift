import AppKit
import CoreServices
import Foundation
import QuartzCore

/// Talks to the Spotify desktop app with raw Apple Events (fast, thread-safe,
/// no AppleScript interpreter) and listens to Spotify's own "playback changed"
/// broadcast so track changes show up instantly.
final class SpotifyClient: @unchecked Sendable {
    static let bundleID = "com.spotify.client"

    enum PlayerState: Equatable { case stopped, playing, paused }

    struct Track: Equatable {
        var id: String
        var name: String
        var artist: String
        var album: String
        var duration: Double      // seconds
        var artworkURL: String
    }

    struct NowPlaying: Equatable {
        var state: PlayerState = .stopped
        var position: Double = 0
        /// When `position` was true (CACurrentMediaTime) — taken the moment Spotify replied.
        var positionTime: Double = 0
        var track: Track?
    }

    enum Access: Equatable { case unknown, granted, denied, notRunning }

    /// Main queue callbacks.
    var onUpdate: ((NowPlaying) -> Void)?
    var onAccess: ((Access) -> Void)?

    private let queue = DispatchQueue(label: "app.aura.spotify", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var lastAccess: Access = .unknown
    private var permissionAsked = false
    private let serialLock = NSLock()
    private var broadcastSerial = 0
    private var serial: Int { serialLock.lock(); defer { serialLock.unlock() }; return broadcastSerial }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    func start() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, queue: .main
        ) { [weak self] note in
            self?.handleBroadcast(note.userInfo ?? [:])
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: 1.0, leeway: .milliseconds(150))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func refresh() { queue.async { [weak self] in self?.poll() } }

    // MARK: Controls

    func playPause() { send(command: "PlPs") }
    func next() { send(command: "Next") }
    func previous() { send(command: "Prev") }

    private func send(command: String) {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            let event = NSAppleEventDescriptor(eventClass: fourCC("spfy"), eventID: fourCC(command),
                                               targetDescriptor: self.target,
                                               returnID: AEReturnID(kAutoGenerateReturnID),
                                               transactionID: AETransactionID(kAnyTransactionID))
            _ = try? event.sendEvent(options: [.waitForReply], timeout: 2)
            self.queue.asyncAfter(deadline: .now() + 0.25) { self.poll() }
        }
    }

    // MARK: Polling

    private var target: NSAppleEventDescriptor { NSAppleEventDescriptor(bundleIdentifier: Self.bundleID) }

    private func poll() {
        guard isRunning else {
            setAccess(.notRunning)
            publish(NowPlaying())
            return
        }
        if !permissionAsked || lastAccess != .granted {
            permissionAsked = true
            // Blocks while macOS shows the one-time "Aura wants to control Spotify" prompt.
            let t = target
            let status = withExtendedLifetime(t) {
                AEDeterminePermissionToAutomateTarget(t.aeDesc, typeWildCard, typeWildCard, true)
            }
            switch status {
            case noErr: setAccess(.granted)
            case OSStatus(errAEEventNotPermitted): setAccess(.denied); return
            case OSStatus(procNotFound): setAccess(.notRunning); return
            default: break    // Spotify still launching; try the real request anyway
            }
        }

        let startSerial = serial
        do {
            let stateCode = try get(property("pPlS")).enumCodeValue
            let state: PlayerState = switch stateCode {
            case fourCC("kPSP"): .playing
            case fourCC("kPSp"): .paused
            default: .stopped
            }
            let asked = CACurrentMediaTime()
            let position = try get(property("pPos")).doubleValue
            let positionTime = (asked + CACurrentMediaTime()) / 2
            var track: Track?
            let current = property("pTrk")
            if let id = try? get(property("ID  ", of: current)).stringValue, !id.isEmpty {
                track = Track(
                    id: id,
                    name: (try? get(property("pnam", of: current)).stringValue) ?? "",
                    artist: (try? get(property("pArt", of: current)).stringValue) ?? "",
                    album: (try? get(property("pAlb", of: current)).stringValue) ?? "",
                    duration: Double((try? get(property("pDur", of: current)).int32Value) ?? 0) / 1000,
                    artworkURL: (try? get(property("aUrl", of: current)).stringValue) ?? ""
                )
            }
            setAccess(.granted)
            // The song changed while reading (fields may mix two songs) — drop it and read again.
            let idAfter = try? get(property("ID  ", of: current)).stringValue
            if idAfter != track?.id || serial != startSerial {
                queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.poll() }
                return
            }
            publish(NowPlaying(state: state, position: position, positionTime: positionTime, track: track))
        } catch let error as NSError {
            if error.code == Int(errAEEventNotPermitted) { setAccess(.denied) }
        }
    }

    private func handleBroadcast(_ info: [AnyHashable: Any]) {
        serialLock.lock(); broadcastSerial += 1; serialLock.unlock()
        // Instant feedback from the broadcast, then a full Apple Event refresh (artwork URL).
        if let stateString = info["Player State"] as? String {
            var now = NowPlaying()
            now.state = stateString == "Playing" ? .playing : stateString == "Paused" ? .paused : .stopped
            now.position = (info["Playback Position"] as? Double) ?? 0
            now.positionTime = CACurrentMediaTime()
            if let id = info["Track ID"] as? String {
                now.track = Track(id: id,
                                  name: info["Name"] as? String ?? "",
                                  artist: info["Artist"] as? String ?? "",
                                  album: info["Album"] as? String ?? "",
                                  duration: ((info["Duration"] as? NSNumber)?.doubleValue ?? 0) / 1000,
                                  artworkURL: "")
            }
            onBroadcast?(now)
        }
        refresh()
    }

    /// The broadcast lacks the artwork URL, so it is delivered separately; the model merges it.
    var onBroadcast: ((NowPlaying) -> Void)?

    // MARK: Apple Event plumbing

    private func property(_ code: String, of container: NSAppleEventDescriptor? = nil) -> NSAppleEventDescriptor {
        let spec = NSAppleEventDescriptor.record().coerce(toDescriptorType: typeObjectSpecifier)!
        spec.setDescriptor(NSAppleEventDescriptor(typeCode: fourCC("prop")), forKeyword: AEKeyword(keyAEDesiredClass))
        spec.setDescriptor(NSAppleEventDescriptor(enumCode: fourCC("prop")), forKeyword: AEKeyword(keyAEKeyForm))
        spec.setDescriptor(NSAppleEventDescriptor(typeCode: fourCC(code)), forKeyword: AEKeyword(keyAEKeyData))
        spec.setDescriptor(container ?? NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
        return spec
    }

    private func get(_ specifier: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
                                           targetDescriptor: target,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(specifier, forKeyword: keyDirectObject)
        let reply = try event.sendEvent(options: [.waitForReply], timeout: 2)
        if let err = reply.paramDescriptor(forKeyword: keyErrorNumber), err.int32Value != 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err.int32Value))
        }
        guard let result = reply.paramDescriptor(forKeyword: keyDirectObject) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errAEDescNotFound))
        }
        return result
    }

    private func setAccess(_ access: Access) {
        guard access != lastAccess else { return }
        lastAccess = access
        DispatchQueue.main.async { [weak self] in self?.onAccess?(access) }
    }

    private func publish(_ now: NowPlaying) {
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(now) }
    }
}

func fourCC(_ s: String) -> FourCharCode {
    s.utf8.prefix(4).reduce(0) { ($0 << 8) | FourCharCode($1) }
}
