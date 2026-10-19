import CoreAudio
import Foundation

struct TapError: LocalizedError {
    let step: String
    let status: OSStatus
    var errorDescription: String? { "\(step) failed (\(status.fourCharDescription))" }
}

/// One Core Audio process tap wrapped in a private aggregate device with an IO block.
/// Tearing it down (or the app quitting) always hands audio back to the tapped app.
final class TapDevice {
    private(set) var tapID = AudioObjectID.unknown
    private(set) var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var format = AudioStreamBasicDescription()

    /// - Parameter outputUID: include this output device (needed to play sound back out);
    ///   `nil` builds a capture-only device that never touches any hardware.
    init(description: CATapDescription, outputUID: String?, io: @escaping AudioDeviceIOBlock) throws {
        do {
            var newTap = AudioObjectID.unknown
            var err = AudioHardwareCreateProcessTap(description, &newTap)
            guard err == noErr else { throw TapError(step: "Creating the audio tap", status: err) }
            tapID = newTap
            format = tapID.read(kAudioTapPropertyFormat, default: format)

            var dict: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Aura Tap",
                kAudioAggregateDeviceUIDKey: "app.aura.tap.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            if let outputUID {
                dict[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
                dict[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
            } else {
                dict[kAudioAggregateDeviceSubDeviceListKey] = [] as [Any]
            }
            var newAggregate = AudioObjectID.unknown
            err = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &newAggregate)
            guard err == noErr, newAggregate.isValid else { throw TapError(step: "Creating the capture device", status: err) }
            aggregateID = newAggregate

            var procID: AudioDeviceIOProcID?
            err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, io)
            guard err == noErr, let procID else { throw TapError(step: "Attaching to the tap", status: err) }
            ioProcID = procID

            err = AudioDeviceStart(aggregateID, procID)
            guard err == noErr else { throw TapError(step: "Starting the tap", status: err) }
        } catch {
            destroy()
            throw error
        }
    }

    func destroy() {
        if aggregateID.isValid {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID.isValid { AudioHardwareDestroyProcessTap(tapID) }
        ioProcID = nil
        aggregateID = .unknown
        tapID = .unknown
    }

    deinit { destroy() }
}

extension AudioObjectID {
    var hasInputStreams: Bool {
        !readArray(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, of: AudioStreamID.self).isEmpty
    }

    /// Seconds between a buffer being handed to the hardware and it leaving the speaker
    /// (converter + DSP latency, excluding the IO buffer itself).
    var presentationLatencySeconds: Double {
        let rate = read(kAudioDevicePropertyNominalSampleRate, default: Float64(48_000))
        guard rate > 0 else { return 0 }
        let scope = kAudioObjectPropertyScopeOutput
        var frames = Double(read(kAudioDevicePropertyLatency, scope: scope, default: UInt32(0)))
        if let first = readArray(kAudioDevicePropertyStreams, scope: scope, of: AudioStreamID.self).first {
            frames += Double(first.read(kAudioStreamPropertyLatency, default: UInt32(0)))
        }
        return frames / rate
    }
}

/// Reads the first two channels (and a mono mix) out of an arbitrary AudioBufferList layout.
/// No heap allocation — safe to use on the real-time audio thread.
struct StereoReader {
    private(set) var frames = 0
    private var lData: UnsafeMutablePointer<Float>?
    private var lStride = 1, lOffset = 0
    private var rData: UnsafeMutablePointer<Float>?
    private var rStride = 1, rOffset = 0

    init(_ list: UnsafeMutableAudioBufferListPointer) {
        var minFrames = Int.max
        for buffer in list {
            guard let raw = buffer.mData else { continue }
            let ch = Int(max(buffer.mNumberChannels, 1))
            minFrames = min(minFrames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * ch))
            let data = raw.assumingMemoryBound(to: Float.self)
            for c in 0..<ch {
                if lData == nil { lData = data; lStride = ch; lOffset = c }
                else if rData == nil { rData = data; rStride = ch; rOffset = c }
            }
        }
        frames = minFrames == .max ? 0 : minFrames
        if rData == nil { rData = lData; rStride = lStride; rOffset = lOffset }
    }

    var isEmpty: Bool { lData == nil || frames == 0 }

    @inline(__always) func left(_ i: Int) -> Float { lData![i * lStride + lOffset] }
    @inline(__always) func right(_ i: Int) -> Float { rData![i * rStride + rOffset] }
}
