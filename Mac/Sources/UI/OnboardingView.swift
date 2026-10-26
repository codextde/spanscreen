import SpanscreenKit
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                AppGlyph(size: 84)
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                Text("Your iPhone is now a display")
                    .font(.system(size: 26, weight: .bold))
                Text("Extend or mirror your Mac to iPhone over Wi-Fi or a USB cable. Free and open source.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .padding(.top, 44)
            .padding(.bottom, 28)

            VStack(spacing: 10) {
                Step(number: 1, title: "Allow Screen Recording", detail: "Spanscreen streams the virtual display to your iPhone. Nothing leaves your network.") {
                    status(model.screenRecordingGranted) { model.requestScreenRecording() }
                }
                Step(number: 2, title: "Allow Accessibility", detail: "Turns taps, drags and two-finger scrolls on iPhone into clicks and scrolls.") {
                    status(model.accessibilityGranted) { model.requestAccessibility() }
                }
                Step(number: 3, title: "Get Spanscreen for iPhone", detail: "Open it on the same Wi-Fi or plug in the cable. Your iPhone appears in the menu bar.") {
                    QRCodeView(url: Spanscreen.iOSAppURL)
                        .frame(width: 58, height: 58)
                        .padding(4)
                        .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(.horizontal, 32)

            Spacer(minLength: 20)

            HStack {
                Toggle("Open at login", isOn: $model.launchAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Spacer()
                Button(action: onDone) {
                    Text("Done").frame(minWidth: 80)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Brand.accent)
                .controlSize(.large)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 26)
        }
        .frame(width: 560, height: 640)
        .background(
            LinearGradient(colors: [Brand.accent.opacity(0.10), .clear], startPoint: .top, endPoint: .center)
        )
        .onAppear { model.refreshPermissions() }
    }

    @ViewBuilder
    private func status(_ granted: Bool, action: @escaping () -> Void) -> some View {
        if granted {
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.green)
        } else {
            Button("Allow…", action: action)
        }
    }
}

private struct Step<Accessory: View>: View {
    let number: Int
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 14) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .frame(width: 26, height: 26)
                .background(Brand.accent.opacity(0.14), in: Circle())
                .foregroundStyle(Brand.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            accessory()
        }
        .padding(14)
        .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary))
    }
}
