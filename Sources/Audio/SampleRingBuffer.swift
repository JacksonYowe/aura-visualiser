import Foundation
import Synchronization

/// Single-writer / single-reader circular buffer of mono samples.
/// The Core Audio IO thread writes, the render loop reads. The only shared
/// state is the total write count, which is atomic, so neither side locks.
final class SampleRingBuffer: @unchecked Sendable {
    let capacity: Int
    private let mask: Int
    private let data: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)

    init(capacityPowerOfTwo log2: Int = 17) {
        capacity = 1 << log2
        mask = capacity - 1
        data = .allocate(capacity: capacity)
        data.initialize(repeating: 0, count: capacity)
    }

    deinit { data.deallocate() }

    /// Total number of samples ever written. Doubles as the "audio clock".
    var totalWritten: Int { written.load(ordering: .acquiring) }

    /// Writer side only (audio thread).
    func write(_ src: UnsafePointer<Float>, count: Int) {
        var w = written.load(ordering: .relaxed)
        var remaining = count
        var offset = 0
        while remaining > 0 {
            let idx = w & mask
            let n = min(remaining, capacity - idx)
            (data + idx).update(from: src + offset, count: n)
            w += n
            offset += n
            remaining -= n
        }
        written.store(w, ordering: .releasing)       // publishes the samples written above
    }

    /// Copies `count` samples that end (exclusive) at absolute sample index `end`.
    /// Anything that was never written, or has already been overwritten, reads as silence.
    func read(into dst: UnsafeMutablePointer<Float>, count: Int, endingAt end: Int) {
        let newest = totalWritten
        let oldest = max(0, newest - capacity + 1)
        var i = 0
        var s = end - count
        while i < count {
            if s < oldest || s >= newest {
                dst[i] = 0
                i += 1
                s += 1
                continue
            }
            let idx = s & mask
            let n = min(count - i, capacity - idx, newest - s)
            (dst + i).update(from: data + idx, count: n)
            i += n
            s += n
        }
    }

    // MARK: - Timing

    /// "Sample `count` reaches your ears at host time `heardAt`" (CACurrentMediaTime seconds).
    /// `writtenAt` is when the writer delivered it, so `heardAt - writtenAt` is the total
    /// delay between the app producing audio and it being heard.
    struct Stamp {
        var count: Int
        var heardAt: Double
        var writtenAt: Double
    }

    private let stampVersion = Atomic<Int>(0)
    private let stampCount = Atomic<Int>(0)
    private let stampHeard = Atomic<UInt64>(0)
    private let stampWritten = Atomic<UInt64>(0)

    /// Writer side only. Seqlock: odd version = write in progress.
    func setStamp(_ s: Stamp) {
        let v = stampVersion.load(ordering: .relaxed)
        stampVersion.store(v | 1, ordering: .relaxed)
        // Release on each field: the odd "write in progress" version above can't be reordered
        // after any of them, so a reader can never see a new field under the old version.
        stampCount.store(s.count, ordering: .releasing)
        stampHeard.store(s.heardAt.bitPattern, ordering: .releasing)
        stampWritten.store(s.writtenAt.bitPattern, ordering: .releasing)
        stampVersion.store((v | 1) + 1, ordering: .releasing)   // publishes the three fields above
    }

    func stamp() -> Stamp? {
        for _ in 0..<64 {
            let v1 = stampVersion.load(ordering: .acquiring)
            if v1 & 1 == 1 { continue }
            let s = Stamp(count: stampCount.load(ordering: .acquiring),
                          heardAt: Double(bitPattern: stampHeard.load(ordering: .acquiring)),
                          writtenAt: Double(bitPattern: stampWritten.load(ordering: .acquiring)))
            if v1 == stampVersion.load(ordering: .acquiring) { return v1 == 0 ? nil : s }
        }
        return nil
    }
}

/// Host-time helpers (mach absolute time ⇄ CACurrentMediaTime seconds).
enum HostClock {
    private static let factor: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()
    static func seconds(_ hostTime: UInt64) -> Double { Double(hostTime) * factor }
    static var now: Double { seconds(mach_absolute_time()) }
}
