// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright © 2026 Jean-Christophe Baptiste

import CoreAudio
import XCTest
@testable import StudioEQ

/// Identity fixtures (serial numbers are fictitious). The Studio Display UID format comes from a public user report
/// (AppleUSBAudioEngine:Apple Inc.:Studio Display:<serial>:8,9); the model UID follows the
/// standard "<product>:<VID>:<PID>" pattern of USB audio devices. Both must be re-checked on
/// real hardware with `StudioEQ --list-devices` (see docs/TESTS.md).
final class MatcherTests: XCTestCase {
    private func device(name: String = "x", uid: String, model: String, maker: String,
                        transport: UInt32 = kAudioDeviceTransportTypeUSB, out: Int = 2) -> OutputDevice {
        OutputDevice(id: 1, uid: uid, name: name, manufacturer: maker, modelUID: model,
                     transportType: transport, outputChannels: out, nominalSampleRate: 48_000)
    }

    func testStudioDisplaySpeakersAreRecognised() {
        let d = device(name: "Haut-parleurs Studio Display",
                       uid: "AppleUSBAudioEngine:Apple Inc.:Studio Display:00000000-0000000000000000:8,9",
                       model: "Studio Display:05AC:1114", maker: "Apple Inc.")
        XCTAssertTrue(StudioDisplayMatcher.isStudioDisplaySpeakers(d))
    }

    func testRecognitionDoesNotDependOnLocalisedNameOrUIDFormat() {
        // Name in another language, new driver (usbaudiod) UID format: model UID still identifies it.
        let d = device(name: "Studio Display スピーカー", uid: "usbaudiod:0x1234:5", model: "Studio Display:05AC:1114", maker: "Apple Inc.")
        XCTAssertTrue(StudioDisplayMatcher.isStudioDisplaySpeakers(d))
        // Manufacturer string missing but Apple VID present.
        XCTAssertTrue(StudioDisplayMatcher.isStudioDisplaySpeakers(device(uid: "u", model: "Studio Display:05AC:1114", maker: "")))
    }

    func testOtherDevicesAreRejected() {
        let cases: [OutputDevice] = [
            device(name: "Haut-parleurs MacBook Pro", uid: "BuiltInSpeakerDevice", model: "Speaker", maker: "Apple Inc.",
                   transport: kAudioDeviceTransportTypeBuiltIn),
            device(name: "AirPods Pro", uid: "AA-BB-CC-DD-EE-FF:output", model: "2014 4c", maker: "Apple Inc.",
                   transport: kAudioDeviceTransportTypeBluetooth),
            // Virtual driver claiming USB transport (eqMac does).
            device(name: "Studio Display", uid: "EQMDevice", model: "EQMDeviceModelUID", maker: "Bitgapp Ltd"),
            // The display's microphone: same model, no output.
            device(uid: "AppleUSBAudioEngine:Apple Inc.:Studio Display:0000:7", model: "Studio Display:05AC:1114",
                   maker: "Apple Inc.", out: 0),
            // Another Apple USB audio product.
            device(uid: "AppleUSBAudioEngine:Apple Inc.:USB-C to 3.5mm Headphone Jack Adapter:1:2",
                   model: "USB-C to 3.5mm Headphone Jack Adapter:05AC:110A", maker: "Apple Inc."),
            // Third-party display.
            device(uid: "AppleUSBAudioEngine:LG Electronics Inc.:LG UltraFine Display Audio:1:2",
                   model: "LG UltraFine Display Audio:043E:9A40", maker: "LG Electronics Inc."),
            // A device merely *named* like the display over AirPlay.
            device(name: "Studio Display", uid: "airplay-1", model: "Studio Display", maker: "Apple Inc.",
                   transport: kAudioDeviceTransportTypeAirPlay),
            // Aggregate whose name mentions the display.
            device(name: "Studio Display + AirPods", uid: "agg:Studio Display", model: "Studio Display:05AC:1114",
                   maker: "Apple Inc.", transport: kAudioDeviceTransportTypeAggregate),
        ]
        for d in cases { XCTAssertFalse(StudioDisplayMatcher.isStudioDisplaySpeakers(d), d.description) }
    }

    func testModelUIDVendorParsing() {
        XCTAssertEqual(StudioDisplayMatcher.modelUIDVendor("Studio Display:05AC:1114"), "05ac")
        XCTAssertEqual(StudioDisplayMatcher.modelUIDVendor("Weird:Name:05ac:1114"), "05ac")
        XCTAssertNil(StudioDisplayMatcher.modelUIDVendor("Speaker"))
        XCTAssertNil(StudioDisplayMatcher.modelUIDVendor("a:ZZZZ:1"))
    }
}
