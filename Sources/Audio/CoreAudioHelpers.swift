import CoreAudio
import Foundation

/// Thin, typed wrappers around the Core Audio property API.
extension AudioObjectID {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != .unknown }

    private func address(_ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    func read<T>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 default value: T) -> T {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        let err = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(self, &addr, 0, nil, &size, $0)
        }
        return err == noErr ? result : value
    }

    func readArray<T>(_ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                      of: T.Type) -> [T] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(self, &addr, 0, nil, &size, buffer) == noErr else { return [] }
        let typed = buffer.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: Int(size) / MemoryLayout<T>.stride))
    }

    func readString(_ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let err = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(self, &addr, 0, nil, &size, $0)
        }
        guard err == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Process object for a PID (or `.unknown` if that process has never touched audio).
    static func processObject(for pid: pid_t) -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var qualifier = pid
        var result = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(.systemObject, &addr,
                                             UInt32(MemoryLayout<pid_t>.size), &qualifier,
                                             &size, &result)
        return err == noErr ? result : .unknown
    }

    static var defaultOutputDevice: AudioObjectID {
        AudioObjectID.systemObject.read(kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID.unknown)
    }

    /// How long (seconds) between audio leaving an app and reaching the speakers.
    /// Bluetooth headphones report ~0.15–0.3 s; built-in speakers a few ms.
    var outputLatencySeconds: Double {
        let rate = read(kAudioDevicePropertyNominalSampleRate, default: Float64(48_000))
        guard rate > 0 else { return 0 }
        let scope = kAudioObjectPropertyScopeOutput
        var frames = Double(read(kAudioDevicePropertyLatency, scope: scope, default: UInt32(0)))
        frames += Double(read(kAudioDevicePropertySafetyOffset, scope: scope, default: UInt32(0)))
        frames += Double(read(kAudioDevicePropertyBufferFrameSize, scope: scope, default: UInt32(0)))
        let streams = readArray(kAudioDevicePropertyStreams, scope: scope, of: AudioStreamID.self)
        if let first = streams.first {
            frames += Double(first.read(kAudioStreamPropertyLatency, default: UInt32(0)))
        }
        return frames / rate
    }
}

/// A process that Core Audio knows about.
struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String

    static func all() -> [AudioProcess] {
        AudioObjectID.systemObject
            .readArray(kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
            .map { id in
                AudioProcess(objectID: id,
                             pid: id.read(kAudioProcessPropertyPID, default: pid_t(-1)),
                             bundleID: id.readString(kAudioProcessPropertyBundleID) ?? "")
            }
    }
}

extension OSStatus {
    var fourCharDescription: String {
        let n = UInt32(bitPattern: self)
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((n >> $0) & 0xFF))) }
        let printable = chars.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " ") }
        return printable ? "'\(String(chars))' (\(self))" : "\(self)"
    }
}
