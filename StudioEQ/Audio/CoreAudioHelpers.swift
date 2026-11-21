// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright © 2026 Jean-Christophe Baptiste

import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let operation: String

    var description: String {
        // Most HAL errors are four-char codes ('who?', '!dev', …).
        let be = UInt32(bitPattern: status).bigEndian
        let bytes = withUnsafeBytes(of: be, Array.init)
        if bytes.allSatisfy({ (0x20...0x7E).contains($0) }), let code = String(bytes: bytes, encoding: .ascii) {
            return "\(operation) failed ('\(code)')"
        }
        return "\(operation) failed (\(status))"
    }
}

@inline(__always)
func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    if status != noErr { throw CoreAudioError(status: status, operation: operation()) }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
}

/// Thin, typed wrappers over AudioObjectGetPropertyData. Main thread / non-real-time use only.
enum HAL {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         initial: T, qualifier: Any? = nil) throws -> T {
        var addr = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value), "get '\(fourCC(selector))'")
        return value
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> String {
        var addr = address(selector, scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value), "get '\(fourCC(selector))'")
        return (value?.takeRetainedValue() as String?) ?? ""
    }

    static func array<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, of: T.Type) throws -> [T] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size), "size '\(fourCC(selector))'")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        return try [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buffer.baseAddress!), "get '\(fourCC(selector))'")
            initialized = Int(size) / MemoryLayout<T>.stride
        }
    }

    static func set<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws {
        var addr = address(selector, scope)
        var v = value
        try check(AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v), "set '\(fourCC(selector))'")
    }

    /// Total channel count of a device in one direction (sum over its streams).
    static func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func defaultOutputDevice() throws -> AudioObjectID {
        try value(.system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(kAudioObjectUnknown))
    }

    static func allDevices() throws -> [AudioObjectID] {
        try array(.system, kAudioHardwarePropertyDevices, of: AudioObjectID.self)
    }

    /// Core Audio's process object for a PID (kAudioObjectUnknown if the process never touched the HAL).
    static func processObject(pid: pid_t) throws -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(.system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
                  "translate PID")
        return object
    }

    static func fourCC(_ v: UInt32) -> String {
        String(bytes: withUnsafeBytes(of: v.bigEndian, Array.init), encoding: .ascii) ?? "\(v)"
    }
}
