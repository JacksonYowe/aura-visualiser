import AppKit
import CoreAudio
import Foundation
import Synchronization

/// Captures what Spotify (or, as a fallback, the whole Mac) is playing using a Core Audio
/// process tap. Nothing is recorded — samples go straight into a ring buffer for the visuals.
///
/// Look-ahead mode: on low-latency outputs (built-in speakers, wired headphones) Spotify's own
/// output is muted and Aura plays the same audio back ~60 ms later. The visuals then get to
/// "see" every beat before you hear it, so they land exactly on time.
final class AudioTap: @unchecked Sendable {
    enum Source: String, CaseIterable, Identifiable {
        case spotify, everything
        var id: String { rawValue }
        var label: String { self == .spotify ? "Spotify only" : "All Mac audio" }
    }

    enum Status: Equatable {
        case stopped
        case listening(spotify: Bool, lookAheadMs: Int)   // lookAheadMs > 0 → sound is being held back
        case failed(String)
    }

    let ring = SampleRingBuffer()
    let sideRing = SampleRingBuffer()
    // Written on the tap queue, read from the IO thread, the render thread and the main thread.
    private let rateBits = Atomic<UInt64>(Double(48_000).bitPattern)
    private let latencyBits = Atomic<UInt64>(Double(0).bitPattern)
    var sampleRate: Double { Double(bitPattern: rateBits.load(ordering: .relaxed)) }
    var outputLatency: Double { Double(bitPattern: latencyBits.load(ordering: .relaxed)) }

    /// Called on the main queue.
    var onStatus: ((Status) -> Void)?

    var preferredSource: Source = .spotify {
        didSet { if oldValue != preferredSource { scheduleRebuild() } }
    }
    /// Hold Spotify's sound back slightly when the output device allows it.
    var lookAheadEnabled = true {
        didSet { if oldValue != lookAheadEnabled { scheduleRebuild(force: true) } }
    }
    static let lookAheadSeconds = 0.060

    private let queue = DispatchQueue(label: "app.aura.tap", qos: .userInitiated)
    private var device: TapDevice?
    private var tappedObjects: Set<AudioObjectID> = []
    private var tappedSpotify = false
    private var listenersInstalled = false
    private var rebuildPending = false
    private var forceNext = false

    let callbackCount = Atomic<Int>(0)

    // IO-thread state (only touched inside the IO block).
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchSide: UnsafeMutablePointer<Float>
    private let scratchCapacity = 16_384
    private let delayL: UnsafeMutablePointer<Float>
    private let delayR: UnsafeMutablePointer<Float>
    private let delayMask = (1 << 15) - 1
    private var delayWrite = 0
    private var ioPassthrough = false
    /// Written on the tap queue (possibly while the IO proc is already running), read on the IO thread.
    private let ioDelayFrames = Atomic<Int>(0)
    private var ioPresentLatency = 0.0

    // Diagnostics written by the IO thread (bit patterns), read by the log.
    let diagInputOffset = Atomic<UInt64>(0)
    let diagOutputOffset = Atomic<UInt64>(0)
    let diagOutputPeak = Atomic<UInt64>(0)

    init() {
        scratch = .allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)
        scratchSide = .allocate(capacity: scratchCapacity)
        scratchSide.initialize(repeating: 0, count: scratchCapacity)
        delayL = .allocate(capacity: 1 << 15)
        delayR = .allocate(capacity: 1 << 15)
        delayL.initialize(repeating: 0, count: 1 << 15)
        delayR.initialize(repeating: 0, count: 1 << 15)
    }

    deinit {
        device?.destroy()          // stops IO before the buffers it reads are freed
        scratch.deallocate(); scratchSide.deallocate(); delayL.deallocate(); delayR.deallocate()
    }

    func start() {
        _ = HostClock.now          // warm the timebase here, not on the first IO callback
        queue.async { [weak self] in self?.installListeners() }
        scheduleRebuild()
    }

    func stop() {
        queue.sync { teardown() }
        publish(.stopped)
    }

    // MARK: - Rebuilding

    func scheduleRebuild(after delay: Double = 0.15, force: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            if force { self.forceNext = true }
            guard !self.rebuildPending else { return }
            self.rebuildPending = true
            self.queue.asyncAfter(deadline: .now() + delay) {
                self.rebuildPending = false
                self.rebuild()
            }
        }
    }

    private func spotifyProcessObjects() -> [AudioObjectID] {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: SpotifyClient.bundleID)
            .map(\.processIdentifier))
        return AudioProcess.all()
            .filter { $0.bundleID.hasPrefix(SpotifyClient.bundleID) || pids.contains($0.pid) }
            .map(\.objectID)
    }

    private func rebuild() {
        let spotify = preferredSource == .spotify ? spotifyProcessObjects() : []
        let wanted = Set(spotify)
        if !forceNext, device != nil, tappedSpotify == !spotify.isEmpty, wanted == tappedObjects { return }
        forceNext = false

        teardown()
        do {
            let lookAhead = try build(processes: spotify)
            tappedSpotify = !spotify.isEmpty
            tappedObjects = wanted
            publish(.listening(spotify: tappedSpotify, lookAheadMs: lookAhead))
        } catch {
            teardown()
            publish(.failed(error.localizedDescription))
        }
    }

    /// Returns the look-ahead in milliseconds (0 when Spotify's sound is untouched).
    private func build(processes: [AudioObjectID]) throws -> Int {
        let output = AudioObjectID.defaultOutputDevice
        let outputUID = output.isValid ? output.readString(kAudioDevicePropertyDeviceUID) : nil
        let latency = output.isValid ? min(output.outputLatencySeconds, 2.0) : 0
        latencyBits.store(latency.bitPattern, ordering: .relaxed)
        let presentLatency = output.isValid ? output.presentationLatencySeconds : 0

        // Only hold sound back where it's safe and useful: a Spotify-only tap, an output with
        // no microphone on the same device (AirPods would drop to call quality) and low latency
        // (Bluetooth already gives plenty of head start).
        let passthrough = lookAheadEnabled && !processes.isEmpty && outputUID != nil
            && !output.hasInputStreams && latency < 0.08

        let description: CATapDescription
        if processes.isEmpty {
            let me = AudioObjectID.processObject(for: ProcessInfo.processInfo.processIdentifier)
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: me.isValid ? [me] : [])
        } else {
            description = CATapDescription(stereoMixdownOfProcesses: processes)
        }
        description.uuid = UUID()
        description.name = "Aura Visualiser Tap"
        description.isPrivate = true
        description.muteBehavior = passthrough ? .mutedWhenTapped : .unmuted

        // Reset IO state before the IO block can run.
        delayL.update(repeating: 0, count: 1 << 15)
        delayR.update(repeating: 0, count: 1 << 15)
        delayWrite = 0
        ioPassthrough = passthrough
        ioPresentLatency = passthrough ? presentLatency : latency
        // Sized from the device's own rate, before the IO block can run.
        let deviceRate = output.isValid ? output.read(kAudioDevicePropertyNominalSampleRate, default: Float64(48_000)) : 48_000
        ioDelayFrames.store(passthrough ? min(Int(Self.lookAheadSeconds * max(deviceRate, 8_000)), delayMask) : 0,
                            ordering: .relaxed)

        let block: AudioDeviceIOBlock = { [weak self] now, input, inTime, output, outTime in
            self?.io(now: now, input: input, inTime: inTime, output: output, outTime: outTime)
        }

        if passthrough {
            let dev = try TapDevice(description: description, outputUID: outputUID, io: block)
            if dev.format.mSampleRate > 0 { rateBits.store(dev.format.mSampleRate.bitPattern, ordering: .relaxed) }
            ioDelayFrames.store(min(Int(Self.lookAheadSeconds * sampleRate), delayMask), ordering: .relaxed)
            device = dev
            return Int(Self.lookAheadSeconds * 1000)
        }

        if let dev = try? TapDevice(description: description, outputUID: nil, io: block) {
            device = dev
        } else {
            description.uuid = UUID()
            device = try TapDevice(description: description, outputUID: outputUID, io: block)
        }
        if let rate = device?.format.mSampleRate, rate > 0 { rateBits.store(rate.bitPattern, ordering: .relaxed) }
        return 0
    }

    private func teardown() {
        device?.destroy()
        device = nil
        tappedObjects = []
        tappedSpotify = false
    }

    // MARK: - IO thread

    private func io(now: UnsafePointer<AudioTimeStamp>, input: UnsafePointer<AudioBufferList>,
                    inTime: UnsafePointer<AudioTimeStamp>, output: UnsafeMutablePointer<AudioBufferList>,
                    outTime: UnsafePointer<AudioTimeStamp>) {
        let count = callbackCount.add(1, ordering: .relaxed).newValue
        let reader = StereoReader(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)))
        let outList = UnsafeMutableAudioBufferListPointer(output)
        let nowSec = HostClock.seconds(now.pointee.mHostTime)
        let rate = sampleRate

        guard !reader.isEmpty else {
            for b in outList { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            return
        }
        let frames = min(reader.frames, scratchCapacity)
        let ringStart = ring.totalWritten

        // Mono for analysis; stereo into the delay line.
        let w = delayWrite
        for i in 0..<frames {
            let l = reader.left(i), r = reader.right(i)
            scratch[i] = (l + r) * 0.5
            scratchSide[i] = (l - r) * 0.5
            delayL[(w + i) & delayMask] = l
            delayR[(w + i) & delayMask] = r
        }
        delayWrite = (w + frames) & delayMask
        ring.write(scratch, count: frames)
        sideRing.write(scratchSide, count: frames)

        let hasIn = inTime.pointee.mFlags.contains(.hostTimeValid)
        let hasOut = outTime.pointee.mFlags.contains(.hostTimeValid)
        let inSec = hasIn ? HostClock.seconds(inTime.pointee.mHostTime) : nowSec
        let outSec = hasOut ? HostClock.seconds(outTime.pointee.mHostTime) : nowSec

        if ioPassthrough {
            // Output frame k plays delay-line sample (w + k - D).
            let delayFrames = ioDelayFrames.load(ordering: .relaxed)
            var peak: Float = 0
            var outFrames = Int.max
            for b in outList { outFrames = min(outFrames, Int(b.mDataByteSize) / (4 * Int(max(b.mNumberChannels, 1)))) }
            if outFrames == .max { outFrames = 0 }
            var monoBuffers = 0
            for b in outList {
                guard let raw = b.mData else { continue }
                memset(raw, 0, Int(b.mDataByteSize))
                let ch = Int(max(b.mNumberChannels, 1))
                let data = raw.assumingMemoryBound(to: Float.self)
                for k in 0..<outFrames {
                    let idx = (w + k - delayFrames) & delayMask
                    if ch >= 2 {
                        data[k * ch] = delayL[idx]
                        data[k * ch + 1] = delayR[idx]
                    } else {
                        data[k] = monoBuffers == 0 ? delayL[idx] : delayR[idx]
                    }
                    peak = max(peak, abs(delayL[idx]))
                }
                if ch == 1 { monoBuffers += 1 }
            }
            // Sample (ringStart - D) is heard at outSec + presentation latency.
            let heard = outSec + ioPresentLatency + Double(frames + delayFrames) / rate
            ring.setStamp(.init(count: ringStart + frames, heardAt: heard, writtenAt: nowSec))
            if count % 50 == 0 { diagOutputPeak.store(Double(peak).bitPattern, ordering: .relaxed) }
        } else {
            for b in outList { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            let heard = inSec + ioPresentLatency + Double(frames) / rate
            ring.setStamp(.init(count: ringStart + frames, heardAt: heard, writtenAt: nowSec))
        }

        if count % 50 == 0 {
            diagInputOffset.store((inSec - nowSec).bitPattern, ordering: .relaxed)
            diagOutputOffset.store((outSec - nowSec).bitPattern, ordering: .relaxed)
        }
    }

    // MARK: - Listeners

    private func installListeners() {
        guard !listenersInstalled else { return }
        listenersInstalled = true

        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            let outputChange = selector == kAudioHardwarePropertyDefaultOutputDevice
            AudioObjectAddPropertyListenerBlock(.systemObject, &addr, queue) { [weak self] _, _ in
                self?.scheduleRebuild(after: 0.4, force: outputChange)
            }
        }

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.bundleIdentifier == SpotifyClient.bundleID { self?.scheduleRebuild(after: 1.0) }
            }
        }
    }

    private func publish(_ status: Status) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(status) }
    }
}
