import AppKit
import SwiftUI

@main
struct SpanscreenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.hasLiveSession ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
                .accessibilityLabel("Spanscreen")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var welcomeWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let dir = UserDefaults.standard.string(forKey: "renderScreens") {
            ScreenRenderer.renderAll(to: URL(fileURLWithPath: dir))
            NSApp.terminate(nil)
            return
        }
        #endif
        AppModel.shared.start()
        if !UserDefaults.standard.bool(forKey: "onboarded") {
            showWelcome()
        }
    }

    func showWelcome() {
        if let welcomeWindow {
            welcomeWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView { [weak self] in
            UserDefaults.standard.set(true, forKey: "onboarded")
            self?.welcomeWindow?.close()
        }
        .environmentObject(AppModel.shared)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        welcomeWindow = window
    }
}

#if DEBUG
@MainActor
enum ScreenRenderer {
    static func renderAll(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel.shared
        model.applyDemo()
        render(MenuContentView().environmentObject(model), name: "mac-menu", to: dir)
        model.applyEmptyDemo()
        render(MenuContentView().environmentObject(model), name: "mac-menu-empty", to: dir)
        render(OnboardingView {}.environmentObject(model), name: "mac-welcome", to: dir)
    }

    private static func render<V: View>(_ view: V, name: String, to dir: URL) {
        for (suffix, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let host = NSHostingView(rootView: view.padding(0))
            host.appearance = NSAppearance(named: appearance)
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.backgroundColor = appearance == .darkAqua ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.97, alpha: 1)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent("\(name)-\(suffix).png"))
            }
        }
    }
}
#endif
