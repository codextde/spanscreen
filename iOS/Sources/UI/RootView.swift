import SpanscreenKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: ReceiverModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPanel = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            DisplaySurface(showPanel: $showPanel)
                .ignoresSafeArea()
                .opacity(model.isLive ? 1 : 0)
                .accessibilityLabel("Mac display")

            if !model.isLive {
                HomeView(showSettings: $showSettings)
                    .transition(.opacity)
            } else {
                StreamOverlay(showPanel: $showPanel)
                    .transition(.opacity)
            }

            if case let .approval(hello) = model.phase {
                ApprovalView(hello: hello)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.isLive)
        .animation(.spring(duration: 0.35), value: model.phase)
        .preferredColorScheme(.dark)
        .statusBarHidden(model.isLive)
        .persistentSystemOverlays(model.isLive ? .hidden : .automatic)
        .defersSystemGestures(on: model.isLive ? .all : [])
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(model)
        }
        .onAppear {
            model.start()
            #if DEBUG
            startDemoIfRequested()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.sceneBecameActive()
            case .background: model.sceneEnteredBackground()
            default: break
            }
        }
        .onChange(of: model.isLive) { _, live in
            if !live { showPanel = false }
        }
        .onChange(of: settings.deviceName) { _, _ in model.renamed() }
    }
}

#if DEBUG
extension RootView {
    private func startDemoIfRequested() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "demoLandscape"), let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
        }
        if defaults.bool(forKey: "demoMacs") {
            model.startDemo(videoSize: .zero, macs: true)
        }
        if let image = DemoContent.image {
            model.startDemo(videoSize: CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale), macs: false)
            if defaults.bool(forKey: "demoPanel") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { showPanel = true }
            }
        }
    }
}

enum DemoContent {
    static let image: UIImage? = UserDefaults.standard.string(forKey: "demoImage").flatMap(UIImage.init(contentsOfFile:))
}
#endif

struct DisplaySurface: UIViewRepresentable {
    @EnvironmentObject private var model: ReceiverModel
    @EnvironmentObject private var settings: AppSettings
    @Binding var showPanel: Bool

    func makeUIView(context: Context) -> InputSurfaceView {
        let view = InputSurfaceView(videoLayer: model.link.renderer.layer)
        let model = model
        view.send = { event in model.send(event) }
        view.onGeometry = { bounds, safeArea, scale, maxFPS in
            model.updateGeometry(bounds: bounds, safeArea: safeArea, scale: scale, maxRefreshRate: maxFPS)
        }
        #if DEBUG
        if let image = DemoContent.image?.cgImage {
            let demo = CALayer()
            demo.contents = image
            demo.contentsGravity = .resizeAspect
            view.demoLayer = demo
        }
        #endif
        return view
    }

    func updateUIView(_ view: InputSurfaceView, context: Context) {
        view.mode = settings.touchMode
        view.trackpadSpeed = settings.trackpadSpeed
        view.videoSize = model.videoSize
        view.contentRect = model.contentRect
        view.onThreeFingerTap = { showPanel.toggle() }
        _ = settings.edgeToEdge
        view.setNeedsLayout()
        if model.keyboardVisible, !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !model.keyboardVisible, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }
}

struct ApprovalView: View {
    @EnvironmentObject private var model: ReceiverModel
    let hello: HostHello

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 84, height: 84)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                VStack(spacing: 6) {
                    Text("Connect to “\(hello.name)”?")
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text("This iPhone becomes a display for the Mac and can control it with touch. You can disconnect at any time.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 12) {
                    Button { model.approve(false) } label: {
                        Text("Don't Allow").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button { model.approve(true) } label: {
                        Text("Allow").fontWeight(.semibold).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                }
                .controlSize(.large)
            }
            .padding(24)
            .frame(maxWidth: 380)
            .glassCard(cornerRadius: 32)
            .padding(24)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: hello.hostID)
    }
}
