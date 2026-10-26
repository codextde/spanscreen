import SpanscreenKit
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: ReceiverModel
    @EnvironmentObject private var settings: AppSettings
    @Binding var showSettings: Bool
    @State private var float = false

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width > proxy.size.height * 1.1
            ZStack {
                AmbientBackground()
                VStack(spacing: 0) {
                    topBar
                    if wide {
                        HStack(alignment: .center, spacing: 40) {
                            hero
                            VStack(spacing: 16) {
                                macsSection
                                macAppButton
                            }
                            .frame(maxWidth: 380)
                        }
                        .frame(maxHeight: .infinity)
                    } else {
                        Spacer(minLength: 12)
                        hero
                        Spacer(minLength: 24)
                        VStack(spacing: 14) {
                            macsSection
                            macAppButton
                        }
                        .frame(maxWidth: 460)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
        }
    }

    private var topBar: some View {
        HStack {
            Text("Spanscreen")
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassCard(cornerRadius: 20)
            .accessibilityLabel("Settings")
        }
        .padding(.top, 8)
    }

    private var hero: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.22))
                    .frame(width: 170, height: 170)
                    .blur(radius: 40)
                Image("Glyph")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 124, height: 124)
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(.white.opacity(0.12)))
                    .shadow(color: .black.opacity(0.4), radius: 24, y: 14)
                    .offset(y: float ? -4 : 4)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) { float = true }
            }

            VStack(spacing: 10) {
                Text(model.requestingMacID == nil ? "Ready to connect" : "Connecting…")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .contentTransition(.opacity)
                Text("Open Spanscreen on your Mac and choose “\(settings.deviceName)”, or pick your Mac below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }

            HStack(spacing: 8) {
                Label {
                    Text(model.serverReady ? "Wi-Fi and USB ready" : "Starting…")
                } icon: {
                    StatusDot(active: model.serverReady)
                }
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassCard(cornerRadius: 18)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var macsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NEARBY MACS")
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            VStack(spacing: 0) {
                if model.nearbyMacs.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView().tint(.secondary)
                        Text("Looking for Macs running Spanscreen…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(16)
                } else {
                    ForEach(Array(model.nearbyMacs.enumerated()), id: \.element.id) { index, mac in
                        if index > 0 { Divider().padding(.leading, 60) }
                        MacRow(mac: mac, connecting: model.requestingMacID == mac.id) {
                            model.request(mac)
                        }
                    }
                }
            }
            .glassCard(cornerRadius: 22)
            if let hint = model.requestHint {
                Label("First time? Click Connect next to “\(settings.deviceName)” in the Spanscreen menu on \(hint).", systemImage: "menubar.arrow.up.rectangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: model.requestHint)
    }

    private var macAppButton: some View {
        ShareLink(item: Spanscreen.macDownloadURL,
                  subject: Text("Spanscreen for Mac"),
                  message: Text("Get Spanscreen for Mac to use your iPhone as a second display.")) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer.and.arrow.down")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Get Spanscreen for Mac").font(.subheadline.weight(.semibold))
                    Text("Free, send the link to your Mac").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassCard(cornerRadius: 22)
    }
}

private struct MacRow: View {
    let mac: NearbyMac
    let connecting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(mac.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if connecting {
                    ProgressView()
                } else {
                    Text("Connect")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(connecting)
    }
}
