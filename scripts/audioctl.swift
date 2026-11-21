// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright © 2026 Jean-Christophe Baptiste

// Test driver for the validation scenarios (not part of the app).
//   swift scripts/audioctl.swift list
//   swift scripts/audioctl.swift default <device-uid>        set the system output device
//   swift scripts/audioctl.swift rate <device-uid> <hz>      set a device's nominal sample rate
//   swift scripts/audioctl.swift fake <uid> <seconds>        publish a selectable aggregate device wrapping the
//                                                            built-in speakers for <seconds>, then remove it
//                                                            (simulates plugging / unplugging an output)
//   swift scripts/audioctl.swift tone <file.wav> <seconds>   write a quiet 440 Hz test tone (−20 dBFS)
// Built by `make build/audioctl`.
import AVFoundation
import CoreAudio
import Foundation

func addr(_ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: sc, mElement: kAudioObjectPropertyElementMain)
}
func devices() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyDevices); var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
    return ids
}
func uid(_ id: AudioObjectID) -> String {
    var a = addr(kAudioDevicePropertyDeviceUID); var v: Unmanaged<CFString>?; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr else { return "?" }
    return v!.takeRetainedValue() as String
}
func device(_ u: String) -> AudioObjectID {
    guard let d = devices().first(where: { uid($0) == u }) else { fputs("no device \(u)\n", stderr); exit(2) }
    return d
}
func number(_ s: String) -> Double {
    guard let v = Double(s) else { fputs("not a number: \(s)\n", stderr); exit(1) }
    return v
}
func rate(_ id: AudioObjectID) -> Double {
    var a = addr(kAudioDevicePropertyNominalSampleRate); var v = 0.0; var size = UInt32(8)
    AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v); return v
}
let args = CommandLine.arguments.dropFirst()
switch args.first {
case "list":
    var a = addr(kAudioHardwarePropertyDefaultOutputDevice); var def = AudioObjectID(0); var size = UInt32(4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &def)
    for d in devices() { print(d == def ? "*" : " ", uid(d), rate(d)) }
case "default" where args.count == 2:
    var a = addr(kAudioHardwarePropertyDefaultOutputDevice); var d = device(args.last!)
    let st = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, 4, &d); print("status", st)
case "rate" where args.count == 3:
    var a = addr(kAudioDevicePropertyNominalSampleRate); var r = number(args.last!)
    let st = AudioObjectSetPropertyData(device(Array(args)[1]), &a, 0, nil, 8, &r); print("status", st)
case "fake" where args.count == 3:
    let a = Array(args)
    let desc: [String: Any] = [kAudioAggregateDeviceNameKey: "Studio EQ Test Output", kAudioAggregateDeviceUIDKey: a[1],
                               kAudioAggregateDeviceMainSubDeviceKey: "BuiltInSpeakerDevice",
                               kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: "BuiltInSpeakerDevice"]]]
    var agg = AudioObjectID(0)
    print("create", AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg), agg)
    Thread.sleep(forTimeInterval: number(a[2]))
    print("destroy", AudioHardwareDestroyAggregateDevice(agg))
case "tone" where args.count == 3:
    let a = Array(args), sampleRate = 48_000.0
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let frames = AVAudioFrameCount(sampleRate * number(a[2]))
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for ch in 0..<2 {
        let p = buffer.floatChannelData![ch]
        for i in 0..<Int(frames) { p[i] = 0.1 * Float(sin(2 * Double.pi * 440 * Double(i) / sampleRate)) }
    }
    do { try AVAudioFile(forWriting: URL(fileURLWithPath: a[1]), settings: format.settings).write(from: buffer) }
    catch { fputs("\(error)\n", stderr); exit(1) }
default:
    print("usage: list | default <uid> | rate <uid> <hz> | fake <uid> <seconds> | tone <file.wav> <seconds>"); exit(1)
}
