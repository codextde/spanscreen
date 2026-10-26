import SpanscreenKit
import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !model.screenRecordingGranted || !model.accessibilityGranted {
                PermissionBanner()
            }
            if model.rows.isEmpty {
                EmptyDevicesView()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Devices")
                    ForEach(model.rows) { row in
                        DeviceCard(row: row, session: model.session(for: row.id))
                    }
                }
            }
            Divider().padding(.horizontal, -14)
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppGlyph(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Spanscreen").font(.system(size: 14, weight: .semibold))
                Text(statusLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Menu {
                Toggle("Open at Login", isOn: $model.launchAtLogin)
                Divider()
                Button("Welcome Guide") { (NSApp.delegate as? AppDelegate)?.showWelcome() }
                Button("Displays Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
                }
                Button("Source Code on GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/codextde/spanscreen")!) }
                Divider()
                Button("Quit Spanscreen") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 15))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var statusLine: String {
        let live = model.sessions.values.filter { $0.phase.isLive }
        if let session = live.first {
            let name = live.count > 1 ? "\(session.name) +\(live.count - 1)" : session.name
            return session.options.mode == .extend ? String(localized: "Extending to \(name)") : String(localized: "Mirroring to \(name)")
        }
        return String(localized: "Your iPhone as a second display")
    }

    private var footer: some View {
        HStack {
            if let version = model.updateAvailable {
                Button {
                    NSWorkspace.shared.open(Spanscreen.macDirectDownloadURL)
                } label: {
                    Label("Update to \(version)", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Brand.accent)
            } else {
                Text("Wi-Fi or USB cable").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
    }
}

struct AppGlyph: View {
    var size: CGFloat
    var body: some View {
        Image("Glyph")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

struct PermissionBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.screenRecordingGranted {
                PermissionRow(title: "Screen Recording", detail: "Needed to show your screen on the iPhone.", granted: false) {
                    model.requestScreenRecording()
                }
            }
            if !model.accessibilityGranted {
                PermissionRow(title: "Accessibility", detail: "Lets you click and scroll with touch.", granted: false) {
                    model.requestAccessibility()
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct PermissionRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted {
                Button("Allow", action: action).controlSize(.small)
            }
        }
    }
}

struct EmptyDevicesView: View {
    var body: some View {
        HStack(spacing: 14) {
            QRCodeView(url: Spanscreen.iOSAppURL)
                .frame(width: 76, height: 76)
                .padding(6)
                .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("Open Spanscreen on your iPhone").font(.system(size: 13, weight: .semibold))
                Text("It shows up here when it is on the same Wi-Fi or connected with a cable. Scan to get the free app.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct DeviceCard: View {
    @EnvironmentObject private var model: AppModel
    let row: DeviceRow
    let session: HostSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isLive ? Brand.accent.opacity(0.15) : Color.primary.opacity(0.06))
                    Image(systemName: deviceSymbol(row.model))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isLive ? Brand.accent : (row.isAvailable ? .primary : .secondary))
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    subtitle
                }
                Spacer(minLength: 6)
                trailing
            }
            if let session = session, session.phase.isLive {
                SessionControls(session: session)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(isLive ? AnyShapeStyle(Brand.accent.opacity(0.06)) : AnyShapeStyle(.quaternary.opacity(0.35)),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(isLive ? Brand.accent.opacity(0.25) : .clear))
        .contextMenu {
            if row.isKnown {
                Button("Forget This Device", role: .destructive) { model.forget(row.id) }
            }
        }
        .animation(.snappy(duration: 0.25), value: session?.phase)
    }

    private var isLive: Bool { session?.phase.isLive == true }

    @ViewBuilder private var subtitle: some View {
        HStack(spacing: 5) {
            if let session = session {
                switch session.phase {
                case .connecting: Text("Connecting…")
                case .awaitingApproval: Text("Confirm on \(row.name)")
                case .starting: Text("Starting display…")
                case .streaming:
                    Pill(text: session.transportKind == .usb ? "USB" : "Wi-Fi", systemImage: session.transportKind == .usb ? "cable.connector" : "wifi", tint: session.transportKind == .usb ? Brand.usb : Brand.accent)
                    if session.stats.framesPerSecond > 0 || session.stats.latencyMilliseconds > 0 {
                        Text("\(Int(session.stats.latencyMilliseconds.rounded())) ms")
                    }
                case .paused: Text("Paused on iPhone")
                case .reconnecting: Text("Reconnecting…")
                case let .failed(message): Text(message).foregroundStyle(.orange)
                case .ended: Text("Disconnected")
                }
            } else if let requested = model.pendingRequests[row.id], requested.timeIntervalSinceNow > -120 {
                Text("Wants to connect, click Connect").foregroundStyle(Brand.accent)
            } else if let failure = model.failures[row.id] {
                Text(failure).foregroundStyle(.orange)
            } else if row.isAvailable {
                if row.viaUSB { Pill(text: "USB", systemImage: "cable.connector", tint: Brand.usb) }
                if row.viaWiFi && !row.viaUSB { Pill(text: "Wi-Fi", systemImage: "wifi", tint: Brand.accent) }
                Text("Ready")
            } else {
                Text("Open Spanscreen on the device")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder private var trailing: some View {
        if let session = session, session.phase != .ended {
            if case .failed = session.phase {
                connectButton
            } else if session.phase.isLive {
                Button("Disconnect") { model.disconnect(row.id) }
                    .controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
            }
        } else if row.isAvailable {
            connectButton
        }
    }

    private var connectButton: some View {
        Button("Connect") { model.connect(row.id) }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .tint(Brand.accent)
    }
}

struct SessionControls: View {
    @ObservedObject var session: HostSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: binding(\.mode)) {
                ForEach(DisplayMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if session.options.mode == .extend {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Text size").font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text(session.options.textSize.title).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "textformat.size.larger").font(.system(size: 11)).foregroundStyle(.secondary)
                        Slider(value: textSizeIndex, in: 0...Double(TextSize.allCases.count - 1), step: 1)
                            .controlSize(.small)
                        Image(systemName: "textformat.size.smaller").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("Position").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Picker("", selection: Binding(get: { session.position ?? .right }, set: { session.place($0) })) {
                        Image(systemName: "rectangle.lefthalf.inset.filled").tag(DisplayPosition.left)
                        Image(systemName: "rectangle.tophalf.inset.filled").tag(DisplayPosition.above)
                        Image(systemName: "rectangle.bottomhalf.inset.filled").tag(DisplayPosition.below)
                        Image(systemName: "rectangle.righthalf.inset.filled").tag(DisplayPosition.right)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Quality").font(.system(size: 11, weight: .medium))
                Picker("", selection: binding(\.quality)) {
                    ForEach(StreamQuality.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if (session.device?.display.maxRefreshRate ?? 60) >= 120 {
                Toggle(isOn: binding(\.highRefreshRate)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("ProMotion 120 Hz").font(.system(size: 11, weight: .medium))
                        Text(session.transportKind == .usb ? "Smoothest motion over USB" : "Works best with a USB cable")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
        }
    }

    private var textSizeIndex: Binding<Double> {
        Binding(
            get: { Double(TextSize.allCases.firstIndex(of: session.options.textSize) ?? 1) },
            set: { value in
                var options = session.options
                options.textSize = TextSize.allCases[Int(value.rounded())]
                session.update(options)
            }
        )
    }

    private func binding<T>(_ keyPath: WritableKeyPath<SessionOptions, T>) -> Binding<T> {
        Binding(
            get: { session.options[keyPath: keyPath] },
            set: { value in
                var options = session.options
                options[keyPath: keyPath] = value
                session.update(options)
            }
        )
    }
}
