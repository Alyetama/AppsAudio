import CoreAudio
import Foundation

/// Thin, throwing-free helpers over the CoreAudio HAL property API.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Read an array-valued property (e.g. the process/object lists).
    static func array<T>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        of type: T.Type
    ) -> [T] {
        var addr = address(selector, scope)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<T>.stride
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &dataSize, raw) == noErr
        else { return [] }
        let bound = raw.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: bound, count: count))
    }

    /// Read a fixed-size scalar property.
    static func value<T>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        default fallback: T
    ) -> T {
        var addr = address(selector, scope)
        var dataSize = UInt32(MemoryLayout<T>.size)
        var result = fallback
        let err = withUnsafeMutablePointer(to: &result) { ptr -> OSStatus in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &dataSize, ptr)
        }
        return err == noErr ? result : fallback
    }

    /// Read a CFString-valued property (bundle ID, device UID, …).
    static func string(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var addr = address(selector, scope)
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var cfStr: CFString? = nil
        let err = withUnsafeMutablePointer(to: &cfStr) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(dataSize)) { raw in
                AudioObjectGetPropertyData(objectID, &addr, 0, nil, &dataSize, raw)
            }
        }
        guard err == noErr, let cfStr else { return nil }
        return cfStr as String
    }

    static func hasProperty(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        var addr = address(selector, scope)
        return AudioObjectHasProperty(objectID, &addr)
    }

    /// The current system default output device.
    static var defaultOutputDevice: AudioObjectID {
        value(system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))
    }

    static func deviceUID(_ device: AudioObjectID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    /// Nominal sample rate of a device.
    static func sampleRate(_ device: AudioObjectID) -> Double {
        value(device, kAudioDevicePropertyNominalSampleRate, default: 48_000.0)
    }
}
