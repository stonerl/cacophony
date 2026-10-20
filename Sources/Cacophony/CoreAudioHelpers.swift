import CoreAudio
import Foundation

enum CoreAudioError: Error, CustomStringConvertible {
    case osStatus(OSStatus, String)

    var description: String {
        switch self {
        case .osStatus(let status, let what):
            return "\(what) failed: OSStatus \(status) ('\(fourCharCode(UInt32(bitPattern: status)))')"
        }
    }
}

func fourCharCode(_ value: UInt32) -> String {
    let bytes = [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
        return String(bytes: bytes, encoding: .ascii)!
    }
    return String(value)
}

func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw CoreAudioError.osStatus(status, what) }
}

func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    func read<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initialValue: T
    ) throws -> T {
        var address = propertyAddress(selector, scope: scope)
        var value = initialValue
        var size = UInt32(MemoryLayout<T>.size)
        try check(
            withUnsafeMutablePointer(to: &value) {
                AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0)
            },
            "AudioObjectGetPropertyData(\(fourCharCode(selector)))"
        )
        return value
    }

    func readString(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> String {
        let value: CFString? = try read(selector, scope: scope, initialValue: nil)
        return (value as String?) ?? ""
    }

    func readArray<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> [T] {
        var address = propertyAddress(selector, scope: scope)
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size),
            "AudioObjectGetPropertyDataSize(\(fourCharCode(selector)))"
        )
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let buffer = UnsafeMutableBufferPointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        try check(
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer.baseAddress!),
            "AudioObjectGetPropertyData(\(fourCharCode(selector)))"
        )
        return Array(buffer)
    }

    static func defaultOutputDevice() throws -> AudioObjectID {
        try AudioObjectID.system.read(
            kAudioHardwarePropertyDefaultOutputDevice,
            initialValue: AudioObjectID(kAudioObjectUnknown)
        )
    }

    static func allDevices() throws -> [AudioObjectID] {
        try AudioObjectID.system.readArray(kAudioHardwarePropertyDevices)
    }

    static func setDefaultOutputDevice(_ device: AudioObjectID) throws {
        var value = device
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        try check(
            AudioObjectSetPropertyData(
                .system, &address, 0, nil,
                UInt32(MemoryLayout<AudioObjectID>.size), &value
            ),
            "SetDefaultOutputDevice"
        )

        address = propertyAddress(kAudioHardwarePropertyDefaultSystemOutputDevice)
        try check(
            AudioObjectSetPropertyData(
                .system, &address, 0, nil,
                UInt32(MemoryLayout<AudioObjectID>.size), &value
            ),
            "SetDefaultSystemOutputDevice"
        )
    }
}
