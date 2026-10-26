import SpanscreenKit
import SwiftUI

struct StreamOverlay: View {
    @EnvironmentObject private var model: ReceiverModel
    @EnvironmentObject private var settings: AppSettings
    @Binding var showPanel: Bool
    @State private var handleDimmed = false
    @State private var dimTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            switch model.phase {
            case let .connecting(name):
                StatusCard(title: "Connecting to \(name)", subtitle: "Setting up the display…", showsDisconnect: false)
            case let .reconnecting(name):
                Color.black.opacity(0.5).ignoresSafeArea().allowsHitTesting(false)
                StatusCard(title: "Reconnecting to \(name)", subtitle: "Keep Spanscreen open on both devices.", showsDisconnect: true)
            default:
                EmptyView()
            }

            if model.phase == .streaming {
                VStack {
                    Spacer()
                    ZStack(alignment: .bottomLeading) {
                        if !showPanel {
                            handle.frame(maxWidth: .infinity)
                        }
                        if settings.showStats {
                            StatsBadge()
                                .padding(.leading, 14)
                                .padding(.bottom, 10)
                        }
                    }
                }
                .allowsHitTesting(!showPanel)
            }

            if showPanel {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { showPanel = false }
                VStack {
                    Spacer()
                    ControlPanel(showPanel: $showPanel)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(duration: 0.38, bounce: 0.18), value: showPanel)
        .onAppear(perform: scheduleDim)
        .onChange(of: showPanel) { _, open in if !open { scheduleDim() } }
    }

    private var handle: some View {
        Button {
            showPanel = true
        } label: {
            Capsule()
                .fill(.white.opacity(handleDimmed ? 0.22 : 0.6))
                .frame(width: 54, height: 5)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show controls")
        .padding(.bottom, 2)
        .animation(.easeInOut(duration: 0.6), value: handleDimmed)
    }

    private func scheduleDim() {
        handleDimmed = false
        dimTask?.cancel()
        dimTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { handleDimmed = true }
        }
    }
}

private struct StatusCard: View {
    @EnvironmentObject private var model: ReceiverModel
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let showsDisconnect: Bool

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large).tint(.white)
            VStack(spacing: 4) {
                Text(title).font(.headline).multilineTextAlignment(.center)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if showsDisconnect {
                Button("Disconnect", role: .destructive) { model.disconnect() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(maxWidth: 320)
        .glassCard(cornerRadius: 28)
    }
}

struct StatsBadge: View {
    @EnvironmentObject private var model: ReceiverModel

    var body: some View {
        let s = model.stats
        Text(statsText(s))
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white.opacity(0.9))
    }

    private func statsText(_ s: LinkStats) -> String {
        let link = model.session?.transport == .usb ? "USB" : "Wi-Fi"
        if s.framesPerSecond < 0.5 { return "\(link)  idle  rtt \(Int(s.roundTripMilliseconds.rounded())) ms" }
        return "\(link)  \(Int(s.framesPerSecond.rounded())) fps  \(Int(s.latencyMilliseconds.rounded())) ms  \(String(format: "%.1f", s.bitrate / 1_000_000)) Mb/s"
    }
}

struct ControlPanel: View {
    @EnvironmentObject private var model: ReceiverModel
    @EnvironmentObject private var settings: AppSettings
    @Binding var showPanel: Bool

    var body: some View {
        VStack(spacing: 16) {
            header
            if let session = model.session {
                Picker("Mode", selection: Binding(get: { session.options.mode }, set: { mode in model.setOptions { $0.mode = mode } })) {
                    Text("Extend").tag(DisplayMode.extend)
                    Text("Mirror").tag(DisplayMode.mirror)
                }
                .pickerStyle(.segmented)

                HStack(spacing: 10) {
                    if session.options.mode == .extend {
                        textSizeControl(session.options.textSize)
                    }
                    Picker("Input", selection: $settings.touchMode) {
                        ForEach(TouchMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.symbol).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            HStack(spacing: 10) {
                PanelButton(title: "Keyboard", symbol: "keyboard", active: model.keyboardVisible) {
                    model.keyboardVisible.toggle()
                    if model.keyboardVisible { showPanel = false }
                }
                PanelButton(title: "Stats", symbol: "speedometer", active: settings.showStats) {
                    settings.showStats.toggle()
                }
                PanelButton(title: "Disconnect", symbol: "xmark.circle", active: false, tint: .red) {
                    showPanel = false
                    model.disconnect()
                }
            }
        }
        .padding(18)
        .frame(maxWidth: 460)
        .glassCard(cornerRadius: 30)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 38, height: 38)
                .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.session?.hostName ?? "Mac").font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: model.session?.transport == .usb ? "cable.connector" : "wifi")
                    Text(detailLine)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showPanel = false
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide controls")
        }
    }

    private var detailLine: String {
        let link = model.session?.transport == .usb ? "USB" : "Wi-Fi"
        let latency = model.stats.latencyMilliseconds
        return latency > 0 ? "\(link) · \(Int(latency.rounded())) ms" : link
    }

    private func textSizeControl(_ size: TextSize) -> some View {
        let all = TextSize.allCases
        let index = all.firstIndex(of: size) ?? 1
        return HStack(spacing: 0) {
            Button {
                model.setOptions { $0.textSize = all[max(0, index - 1)] }
            } label: {
                Image(systemName: "textformat.size.larger").frame(width: 40, height: 32)
            }
            .disabled(index == 0)
            .accessibilityLabel("Larger text")
            Divider().frame(height: 18)
            Button {
                model.setOptions { $0.textSize = all[min(all.count - 1, index + 1)] }
            } label: {
                Image(systemName: "textformat.size.smaller").frame(width: 40, height: 32)
            }
            .disabled(index == all.count - 1)
            .accessibilityLabel("More space")
        }
        .buttonStyle(.plain)
        .font(.system(size: 14, weight: .medium))
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct PanelButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let active: Bool
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                Text(title).font(.caption.weight(.medium))
            }
            .foregroundStyle(active ? Theme.accent : tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background((active ? Theme.accent : Color.white).opacity(active ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
