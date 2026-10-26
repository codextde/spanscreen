import SwiftUI

enum Theme {
    static let accent = Color(red: 0.18, green: 0.42, blue: 1.0)
    static let teal = Color(red: 0.36, green: 0.90, blue: 0.81)
    static let background = Color(red: 0.035, green: 0.047, blue: 0.078)
    static let card = Color.white.opacity(0.06)
    static let stroke = Color.white.opacity(0.09)
}

struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 26

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.stroke))
        }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 26) -> some View { modifier(GlassCard(cornerRadius: cornerRadius)) }
}

struct StatusDot: View {
    let active: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(active ? Color.green.opacity(0.35) : .clear)
                .frame(width: 14, height: 14)
                .scaleEffect(pulse ? 1.25 : 0.6)
                .opacity(pulse ? 0 : 1)
            Circle()
                .fill(active ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

struct AmbientBackground: View {
    @State private var drift = false

    var body: some View {
        ZStack {
            Theme.background
            Circle()
                .fill(Theme.accent.opacity(0.32))
                .frame(width: 420, height: 420)
                .blur(radius: 120)
                .offset(x: drift ? -70 : -20, y: drift ? -260 : -200)
            Circle()
                .fill(Theme.teal.opacity(0.18))
                .frame(width: 360, height: 360)
                .blur(radius: 120)
                .offset(x: drift ? 120 : 80, y: drift ? 260 : 300)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { drift = true }
        }
    }
}
