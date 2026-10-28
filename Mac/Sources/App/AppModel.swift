import AppKit
import Combine
import CoreGraphics
import Foundation
import ServiceManagement
import SpanscreenKit

struct KnownDevice: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var model: String
    var autoConnect: Bool
    var options: SessionOptions
    var lastConnected: Date
}

struct DeviceRow: Identifiable, Equatable {
    let id: String
    var name: String
    var model: String
    var isAvailable: Bool
    var viaUSB: Bool
    var viaWiFi: Bool
    var isKnown: Bool
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var rows: [DeviceRow] = []
    @Published private(set) var sessions: [String: HostSession] = [:]
    @Published private(set) var known: [String: KnownDevice] = [:]
    @Published private(set) var screenRecordingGranted = CGPreflightScreenCaptureAccess()
    @Published private(set) var accessibilityGranted = InputInjector.isTrusted
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }
    @Published var defaultOptions: SessionOptions {
        didSet { save() }
    }
    @Published private(set) var failures: [String: String] = [:]
    @Published private(set) var updateAvailable: String?
    @Published private(set) var pendingRequests: [String: Date] = [:]

    private let directory = DeviceDirectory()
    private var sessionObservers: [String: AnyCancellable] = [:]
    private var permissionTimer: Timer?
    private var lastAvailable = Set<String>()
    private var suppressed = Set<String>()

    var hasLiveSession: Bool { sessions.values.contains { $0.phase.isLive } }

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "knownDevices"), let list = try? JSONDecoder().decode([KnownDevice].self, from: data) {
            known = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        }
        if let data = defaults.data(forKey: "defaultOptions"), let options = try? JSONDecoder().decode(SessionOptions.self, from: data) {
            defaultOptions = options
        } else {
            defaultOptions = SessionOptions()
        }
    }

    func start() {
        directory.onChange = { [weak self] in self?.directoryChanged() }
        directory.onConnectRequest = { [weak self] request in self?.handleConnectRequest(request) }
        directory.start()
        schedulePermissionChecks()
        rebuildRows()
        Task { await checkForUpdate() }
    }

    func refreshPermissions() {
        let screen = CGPreflightScreenCaptureAccess()
        let accessibility = InputInjector.isTrusted
        if screen != screenRecordingGranted { screenRecordingGranted = screen }
        if accessibility != accessibilityGranted { accessibilityGranted = accessibility }
        schedulePermissionChecks()
    }

    private func schedulePermissionChecks() {
        let interval: TimeInterval = screenRecordingGranted && accessibilityGranted ? 30 : 2
        if let timer = permissionTimer, timer.isValid, timer.timeInterval == interval { return }
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
    }

    func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    func requestAccessibility() {
        InputInjector.requestTrust()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func connect(_ deviceID: String, requestedByDevice: Bool = false, userInitiated: Bool = true) {
        if userInitiated || requestedByDevice {
            failures[deviceID] = nil
            suppressed.remove(deviceID)
            pendingRequests[deviceID] = nil
        }
        if let session = sessions[deviceID], session.phase != .ended, !isFailed(session.phase) { return }
        guard let entry = directory.entries[deviceID], let route = entry.bestRoute else { return }
        if userInitiated, !screenRecordingGranted { requestScreenRecording() }
        let options = known[deviceID]?.options ?? defaultOptions
        let session = HostSession(deviceID: deviceID, name: entry.name, options: options, requestedByDevice: requestedByDevice, userInitiated: userInitiated)
        session.routeProvider = { [weak self] in self?.directory.entries[deviceID]?.bestRoute }
        session.onAccepted = { [weak self] info, options in self?.remember(info, options: options) }
        session.onEnded = { [weak self] session in self?.sessionEnded(session) }
        sessions[deviceID] = session
        directory.markBusy(deviceID, true)
        sessionObservers[deviceID] = session.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.objectWillChange.send()
                self?.persistOptions(of: session)
            }
        }
        session.connect(route)
        rebuildRows()
    }

    func disconnect(_ deviceID: String) {
        suppressed.insert(deviceID)
        sessions[deviceID]?.disconnect()
    }

    func forget(_ deviceID: String) {
        sessions[deviceID]?.disconnect()
        known[deviceID] = nil
        HostSession.pairings.setKey(nil, for: deviceID)
        save()
        rebuildRows()
    }

    func setAutoConnect(_ deviceID: String, _ value: Bool) {
        known[deviceID]?.autoConnect = value
        save()
    }

    func session(for id: String) -> HostSession? { sessions[id] }

    private func isFailed(_ phase: HostSession.Phase) -> Bool {
        if case .failed = phase { return true }
        return false
    }

    private func sessionEnded(_ session: HostSession) {
        guard sessions[session.id] === session else { return }
        if case let .failed(message) = session.phase { failures[session.id] = message }
        if session.endedByDevice { suppressed.insert(session.id) }
        sessions[session.id] = nil
        sessionObservers[session.id] = nil
        directory.markBusy(session.id, false)
        rebuildRows()
    }

    private func remember(_ info: DeviceInfo, options: SessionOptions) {
        var device = known[info.deviceID] ?? KnownDevice(id: info.deviceID, name: info.name, model: info.model, autoConnect: true, options: options, lastConnected: Date())
        device.name = info.name
        device.model = info.model
        device.autoConnect = true
        device.lastConnected = Date()
        known[info.deviceID] = device
        failures[info.deviceID] = nil
        save()
        rebuildRows()
    }

    private func persistOptions(of session: HostSession) {
        guard var device = known[session.id], device.options != session.options else { return }
        device.options = session.options
        known[session.id] = device
        save()
    }

    private func handleConnectRequest(_ request: ConnectRequest) {
        guard known[request.deviceID] != nil, HostSession.pairings.key(for: request.deviceID) != nil else {
            pendingRequests[request.deviceID] = Date()
            return
        }
        if let session = sessions[request.deviceID], session.phase.isLive { return }
        Task {
            for _ in 0..<10 {
                if directory.entries[request.deviceID]?.bestRoute != nil {
                    connect(request.deviceID, requestedByDevice: true, userInitiated: false)
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func directoryChanged() {
        let available = Set(directory.entries.values.filter(\.isAvailable).map(\.id))
        for id in available.subtracting(lastAvailable) {
            failures[id] = nil
            suppressed.remove(id)
        }
        lastAvailable = available
        for entry in directory.entries.values {
            if let session = sessions[entry.id] {
                if let usb = entry.usb, session.transportKind == .wifi, session.phase == .streaming {
                    session.upgrade(to: .usb(usb))
                }
                continue
            }
            let forced = ProcessInfo.processInfo.environment["SPANSCREEN_AUTOCONNECT"] == "1"
            let autoConnect = known[entry.id]?.autoConnect == true || forced
            if entry.isAvailable, autoConnect, failures[entry.id] == nil, !suppressed.contains(entry.id) {
                connect(entry.id, userInitiated: forced && known[entry.id] == nil)
            }
        }
        rebuildRows()
    }

    private func rebuildRows() {
        var result: [String: DeviceRow] = [:]
        for entry in directory.entries.values {
            result[entry.id] = DeviceRow(id: entry.id, name: entry.info?.name ?? entry.name, model: entry.info?.model ?? entry.model,
                                         isAvailable: entry.isAvailable, viaUSB: entry.usb != nil, viaWiFi: entry.wifi != nil, isKnown: known[entry.id] != nil)
        }
        for device in known.values where result[device.id] == nil {
            result[device.id] = DeviceRow(id: device.id, name: device.name, model: device.model, isAvailable: false, viaUSB: false, viaWiFi: false, isKnown: true)
        }
        for (id, session) in sessions where result[id] == nil {
            result[id] = DeviceRow(id: id, name: session.name, model: session.device?.model ?? "iPhone", isAvailable: true, viaUSB: session.transportKind == .usb, viaWiFi: session.transportKind == .wifi, isKnown: known[id] != nil)
        }
        rows = result.values.sorted { lhs, rhs in
            let l = (sessions[lhs.id] != nil, lhs.isAvailable, lhs.name)
            let r = (sessions[rhs.id] != nil, rhs.isAvailable, rhs.name)
            if l.0 != r.0 { return l.0 }
            if l.1 != r.1 { return l.1 }
            return l.2.localizedStandardCompare(r.2) == .orderedAscending
        }
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(Array(known.values)), forKey: "knownDevices")
        defaults.set(try? JSONEncoder().encode(defaultOptions), forKey: "defaultOptions")
    }

    #if DEBUG
    func applyDemo() {
        let display = DisplayInfo(pixelWidth: 2852, pixelHeight: 2006, scale: 3, pixelsPerInch: 460, maxRefreshRate: 120)
        let duo = DeviceInfo(deviceID: "duo", name: "Daniel's iPhone Duo", model: "iPhone19,4", appVersion: "1.0.0", display: display)
        let session = HostSession(deviceID: "duo", name: duo.name, options: SessionOptions(highRefreshRate: true), requestedByDevice: false, userInitiated: true)
        session.applyDemo(device: duo, transport: .usb)
        sessions = ["duo": session]
        rows = [
            DeviceRow(id: "duo", name: duo.name, model: "iPhone19,4", isAvailable: true, viaUSB: true, viaWiFi: true, isKnown: true),
            DeviceRow(id: "ipad", name: "iPad Pro", model: "iPad16,3", isAvailable: true, viaUSB: false, viaWiFi: true, isKnown: false)
        ]
        screenRecordingGranted = true
        accessibilityGranted = true
    }

    func applyEmptyDemo() {
        sessions = [:]
        rows = []
        screenRecordingGranted = true
        accessibilityGranted = false
    }
    #endif

    private func checkForUpdate() async {
        guard let url = URL(string: "https://api.github.com/repos/codextde/spanscreen/releases/latest"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return }
        let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        if latest.compare(HostIdentity.shared.appVersion, options: .numeric) == .orderedDescending {
            updateAvailable = latest
        }
    }
}
