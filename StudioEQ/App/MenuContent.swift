// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Jean-Christophe Baptiste

import SwiftUI

/// The whole UI: one compact panel under the menu bar icon.
struct MenuContent: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            Toggle("Equalization", isOn: $model.isEnabled)
                .toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 8) {
                band("Bass", detail: "Low shelf · 150 Hz", value: $model.settings.bass)
                band("Mids", detail: "Peak · 1.5 kHz", value: $model.settings.mid)
                band("Treble", detail: "High shelf · 6 kHz", value: $model.settings.treble)
            }
            .disabled(!model.isEnabled)
            HStack {
                Text("Preamp")
                    .foregroundStyle(.secondary)
                Text(verbatim: Self.dB(EQDesign.preampDB))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset to Defaults") { model.resetToDefaults() }
                    .disabled(model.settings == .defaults)
            }
            .font(.callout)
            Divider()
            Toggle("Open at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            if let error = model.launchAtLoginError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Hide Icon Without Studio Display", isOn: $model.hideIconWithoutDisplay)
                if model.hideIconWithoutDisplay {
                    Text("To show it again, open Studio EQ again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            Button("Quit Studio EQ") { model.shutdown(); NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 300)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text("Studio EQ").font(.headline)
            }
            statusText
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch model.status {
            case .error:
                Button("Retry") { model.retry() }
            case .permissionDenied:
                HStack {
                    Button("Open Privacy Settings") { model.openPrivacySettings() }
                    Button("Retry") { model.retry() }
                }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var statusText: some View {
        switch model.status {
        case .active:
            Text("Active on \(model.currentOutput?.name ?? "")")
        case .disabled:
            Text("Equalization is off.")
        case .noDisplay:
            Text("Inactive: no Studio Display speakers connected.")
        case .otherOutput:
            Text("Inactive: the sound output is \(model.currentOutput?.name ?? String(localized: "another device")).")
        case .checkingPermission:
            Text("Checking audio capture permission…")
        case .permissionDenied:
            Text("Audio capture permission is missing. Allow Studio EQ in System Settings › Privacy & Security › Screen & System Audio Recording.")
        case .error(let message):
            Text("Error: \(message)")
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .active: .green
        case .error, .permissionDenied: .orange
        default: .secondary
        }
    }

    private func band(_ title: LocalizedStringKey, detail: LocalizedStringKey, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Text(verbatim: Self.dB(value.wrappedValue)).monospacedDigit()
            }
            Slider(value: value, in: EQSettings.gainRange, step: 0.5)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(verbatim: Self.dB(value.wrappedValue)))
        }
    }

    static func dB(_ v: Double) -> String {
        let s = String(format: "%+.1f dB", v)
        return s.replacingOccurrences(of: "-", with: "−")
    }
}
