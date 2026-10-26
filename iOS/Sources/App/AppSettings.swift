import Foundation
import SpanscreenKit

enum TouchMode: String, CaseIterable, Identifiable {
    case touch
    case trackpad

    var id: String { rawValue }
    var title: String { self == .touch ? "Touch" : "Trackpad" }
    var symbol: String { self == .touch ? "hand.tap" : "rectangle.and.hand.point.up.left" }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var deviceName: String { didSet { defaults.set(deviceName, forKey: "deviceName") } }
    @Published var touchMode: TouchMode { didSet { defaults.set(touchMode.rawValue, forKey: "touchMode") } }
    @Published var edgeToEdge: Bool { didSet { defaults.set(edgeToEdge, forKey: "edgeToEdge") } }
    @Published var showStats: Bool { didSet { defaults.set(showStats, forKey: "showStats") } }
    @Published var trackpadSpeed: Double { didSet { defaults.set(trackpadSpeed, forKey: "trackpadSpeed") } }
    @Published private(set) var trustedHosts: [String: String] { didSet { defaults.set(trustedHosts, forKey: "trustedHosts") } }

    private init() {
        deviceName = defaults.string(forKey: "deviceName") ?? DeviceIdentity.marketingName
        touchMode = TouchMode(rawValue: defaults.string(forKey: "touchMode") ?? "") ?? .touch
        edgeToEdge = defaults.object(forKey: "edgeToEdge") as? Bool ?? true
        showStats = defaults.bool(forKey: "showStats")
        trackpadSpeed = defaults.object(forKey: "trackpadSpeed") as? Double ?? 1.0
        trustedHosts = defaults.dictionary(forKey: "trustedHosts") as? [String: String] ?? [:]
    }

    func trust(_ hello: HostHello) { trustedHosts[hello.hostID] = hello.name }
    func forget(_ hostID: String) {
        trustedHosts[hostID] = nil
        PairingStore().setKey(nil, for: hostID)
    }
}
