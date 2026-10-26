import SpanscreenKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $settings.deviceName)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                } header: {
                    Text("This \(DeviceIdentity.isPad ? "iPad" : "iPhone")")
                } footer: {
                    Text("Your Mac shows this name in the Spanscreen menu.")
                }

                Section("Input") {
                    Picker("Control", selection: $settings.touchMode) {
                        ForEach(TouchMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    if settings.touchMode == .trackpad {
                        VStack(alignment: .leading) {
                            Text("Pointer speed")
                            Slider(value: $settings.trackpadSpeed, in: 0.4...2.5)
                        }
                    }
                }

                Section {
                    Toggle("Use the whole screen", isOn: $settings.edgeToEdge)
                    Toggle("Show connection stats", isOn: $settings.showStats)
                } header: {
                    Text("Display")
                } footer: {
                    Text("Turn off to keep the Mac picture clear of the camera area.")
                }

                if !settings.trustedHosts.isEmpty {
                    Section {
                        ForEach(settings.trustedHosts.sorted(by: { $0.value < $1.value }), id: \.key) { id, name in
                            Label(name, systemImage: "laptopcomputer")
                                .swipeActions {
                                    Button("Forget", role: .destructive) { settings.forget(id) }
                                }
                        }
                    } header: {
                        Text("Trusted Macs")
                    } footer: {
                        Text("These Macs connect without asking. Swipe to forget one.")
                    }
                }

                Section("Gestures") {
                    GestureRow(symbol: "hand.tap", title: "Tap", detail: "Click")
                    GestureRow(symbol: "hand.point.up.left", title: "Touch and hold", detail: "Right-click")
                    GestureRow(symbol: "hand.draw", title: "Drag", detail: "Drag windows and select")
                    GestureRow(symbol: "arrow.up.and.down", title: "Two-finger drag", detail: "Scroll")
                    GestureRow(symbol: "hand.tap.fill", title: "Two-finger tap", detail: "Right-click")
                    GestureRow(symbol: "slider.horizontal.3", title: "Three-finger tap", detail: "Show controls")
                }

                Section {
                    ShareLink(item: Spanscreen.macDownloadURL) {
                        Label("Get Spanscreen for Mac", systemImage: "laptopcomputer.and.arrow.down")
                    }
                    Link(destination: URL(string: "https://github.com/codextde/spanscreen")!) {
                        Label("Source Code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Link(destination: URL(string: "https://codextde.github.io/spanscreen/privacy.html")!) {
                        Label("Privacy", systemImage: "hand.raised")
                    }
                } footer: {
                    Text("Spanscreen \(DeviceIdentity.appVersion) by Codext. Free and open source. No account, no tracking: video and input stay on your local network or cable.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct GestureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack {
            Image(systemName: symbol)
                .frame(width: 28)
                .foregroundStyle(Theme.accent)
            Text(title)
            Spacer()
            Text(detail).foregroundStyle(.secondary)
        }
    }
}
