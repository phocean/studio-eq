// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright © 2026 Jean-Christophe Baptiste

import CoreAudio
import Foundation

/// Hardware identity of an output device, as reported by the HAL.
struct OutputDevice: Equatable, Sendable, CustomStringConvertible {
    let id: AudioObjectID
    let uid: String           // kAudioDevicePropertyDeviceUID — stable per unit and port
    let name: String          // localised, display only (never used for matching)
    let manufacturer: String
    let modelUID: String      // kAudioDevicePropertyModelUID — same for every unit of a model
    let transportType: UInt32
    let outputChannels: Int
    let nominalSampleRate: Double

    static func read(_ id: AudioObjectID) -> OutputDevice? {
        guard let uid = try? HAL.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return OutputDevice(
            id: id,
            uid: uid,
            name: (try? HAL.string(id, kAudioObjectPropertyName)) ?? "",
            manufacturer: (try? HAL.string(id, kAudioObjectPropertyManufacturer)) ?? "",
            modelUID: (try? HAL.string(id, kAudioDevicePropertyModelUID)) ?? "",
            transportType: (try? HAL.value(id, kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0,
            outputChannels: HAL.channelCount(id, scope: kAudioObjectPropertyScopeOutput),
            nominalSampleRate: (try? HAL.value(id, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))) ?? 0)
    }

    var description: String {
        "\(name) [uid=\(uid) model=\(modelUID) maker=\(manufacturer) transport=\(HAL.fourCC(transportType)) out=\(outputChannels)ch \(Int(nominalSampleRate))Hz]"
    }
}

/// Decides whether a device is the Apple Studio Display's speaker output.
///
/// The localised display name ("Studio Display Speakers", "Haut-parleurs Studio Display"…) is
/// never used. The decision relies on hardware-derived, non-localised properties:
///  • transport is USB (the display's audio is a USB Audio Class function, also over Thunderbolt);
///  • the vendor is Apple — USB vendor ID 0x05AC in the model UID, or manufacturer "Apple Inc.";
///  • the USB product string "Studio Display" appears in the model UID or device UID (both are
///    built by the USB audio driver from the device descriptors, e.g.
///    "AppleUSBAudioEngine:Apple Inc.:Studio Display:<serial>:8,9");
///  • the device actually has output channels (the display's microphone is a separate device).
/// Virtual drivers can claim USB transport (eqMac does), hence the vendor check.
enum StudioDisplayMatcher {
    static let appleVendorID = "05ac"
    static let productString = "studio display"

    static func isStudioDisplaySpeakers(_ d: OutputDevice) -> Bool {
        guard d.outputChannels > 0 else { return false }
        guard d.transportType == kAudioDeviceTransportTypeUSB || d.transportType == kAudioDeviceTransportTypeThunderbolt
        else { return false }
        let model = d.modelUID.lowercased()
        let uid = d.uid.lowercased()
        let vendorIsApple = modelUIDVendor(d.modelUID) == appleVendorID || d.manufacturer == "Apple Inc."
        let productMatches = model.contains(productString) || uid.contains(":\(productString)")
        return vendorIsApple && productMatches
    }

    /// USB audio model UIDs are "<product>:<VID>:<PID>" with hex IDs. Returns the lowercase VID.
    static func modelUIDVendor(_ modelUID: String) -> String? {
        let parts = modelUID.split(separator: ":")
        guard parts.count >= 3 else { return nil }
        let vid = parts[parts.count - 2].lowercased()
        return vid.count == 4 && vid.allSatisfy(\.isHexDigit) ? vid : nil
    }
}
