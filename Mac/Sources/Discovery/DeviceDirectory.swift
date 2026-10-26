import Foundation
import Network
import SpanscreenKit

struct HostIdentity {
    static let shared = HostIdentity()

    let hostID: String = {
        let key = "hostID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    var name: String { Host.current().localizedName ?? "Mac" }

    var model: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }

    func hello(_ intent: HostIntent, requestedByDevice: Bool = false) -> HostHello {
        HostHello(hostID: hostID, name: name, model: model, appVersion: appVersion, intent: intent, requestedByDevice: requestedByDevice)
    }
}

enum Route {
    case usb(USBDevice)
    case wifi(NWEndpoint)

    var kind: TransportKind {
        if case .usb = self { return .usb }
        return .wifi
    }
}

struct DirectoryEntry: Identifiable, Equatable {
    let id: String
    var name: String
    var model: String
    var wifi: NWEndpoint?
    var usb: USBDevice?
    var info: DeviceInfo?

    var bestRoute: Route? {
        if let usb { return .usb(usb) }
        if let wifi { return .wifi(wifi) }
        return nil
    }

    var isAvailable: Bool { wifi != nil || usb != nil }
}

@MainActor
final class DeviceDirectory {
    var onChange: (() -> Void)?
    var onConnectRequest: ((ConnectRequest) -> Void)?
    private(set) var entries: [String: DirectoryEntry] = [:]

    private let queue = DispatchQueue(label: "de.codext.spanscreen.directory")
    private var browser: NWBrowser?
    private var hostListener: NWListener?
    private let usb = USBMux()
    private var usbAttached: [Int: USBDevice] = [:]
    private var usbOwner: [Int: String] = [:]
    private var probing = Set<Int>()
    private var probeTimer: Timer?
    private var wifiResults: [String: (endpoint: NWEndpoint, name: String, model: String)] = [:]
    private var busyDevices = Set<String>()

    func start() {
        startBrowser()
        startHostListener()
        usb.onAttached = { [weak self] device in
            self?.usbAttached[device.muxID] = device
            self?.probe(device)
        }
        usb.onDetached = { [weak self] id in
            guard let self else { return }
            self.usbAttached[id] = nil
            self.usbOwner[id] = nil
            self.rebuild()
        }
        usb.start()
        probeTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.probeUnknownDevices() }
        }
    }

    func markBusy(_ deviceID: String, _ busy: Bool) {
        if busy { busyDevices.insert(deviceID) } else { busyDevices.remove(deviceID) }
    }

    private func probeUnknownDevices() {
        for device in usbAttached.values where usbOwner[device.muxID] == nil {
            probe(device)
        }
        for (mux, owner) in usbOwner where !busyDevices.contains(owner) {
            if let device = usbAttached[mux] { probe(device, revalidate: true) }
        }
    }

    private func probe(_ device: USBDevice, revalidate: Bool = false) {
        guard !probing.contains(device.muxID) else { return }
        probing.insert(device.muxID)
        Task {
            defer { probing.remove(device.muxID) }
            do {
                let fd = try await USBMux.connect(device: device, port: Spanscreen.devicePort)
                let transport = SocketTransport(fileDescriptor: fd, queue: queue)
                let info = try await Self.probe(transport)
                guard usbAttached[device.muxID] != nil else { return }
                usbOwner[device.muxID] = info.deviceID
                entries[info.deviceID, default: DirectoryEntry(id: info.deviceID, name: info.name, model: info.model)].info = info
                rebuild()
            } catch {
                if revalidate, usbOwner[device.muxID] != nil {
                    usbOwner[device.muxID] = nil
                    rebuild()
                }
            }
        }
    }

    private static func probe(_ transport: MessageTransport) async throws -> DeviceInfo {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DeviceInfo, Error>) in
            let lock = NSLock()
            var done = false
            func finish(_ result: Result<DeviceInfo, Error>) {
                lock.lock()
                guard !done else { lock.unlock(); return }
                done = true
                lock.unlock()
                transport.close()
                continuation.resume(with: result)
            }
            transport.onReady = { transport.send(.hostHello, HostIdentity.shared.hello(.probe)) }
            transport.onMessage = { message in
                if message.type == .deviceInfo, let info = message.decode(DeviceInfo.self) { finish(.success(info)) }
            }
            transport.onClose = { error in finish(.failure(error ?? USBMuxError.protocolError)) }
            transport.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish(.failure(USBMuxError.protocolError)) }
        }
    }

    private func startBrowser() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Spanscreen.displayServiceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            log.info("bonjour results \(results.count)")
            var found: [String: (NWEndpoint, String, String)] = [:]
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint,
                      case let .bonjour(txt) = result.metadata, let id = txt["id"], !id.isEmpty else { continue }
                found[id] = (result.endpoint, name, txt["model"] ?? "iPhone")
            }
            Task { @MainActor in
                self?.wifiResults = found.mapValues { (endpoint: $0.0, name: $0.1, model: $0.2) }
                self?.rebuild()
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            log.info("browser state \(String(describing: state), privacy: .public)")
            if case .failed = state {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    self?.startBrowser()
                }
            }
        }
        browser.start(queue: queue)
        self.browser?.cancel()
        self.browser = browser
    }

    private func startHostListener() {
        guard let listener = try? NWListener(using: NetworkConfig.tcp()) else { return }
        let identity = HostIdentity.shared
        var txt = NWTXTRecord()
        txt["id"] = identity.hostID
        txt["model"] = identity.model
        listener.service = NWListener.Service(name: identity.name, type: Spanscreen.hostServiceType, txtRecord: txt)
        listener.newConnectionHandler = { [weak self, queue] connection in
            let transport = NetworkTransport(connection: connection, queue: queue)
            transport.onMessage = { message in
                guard message.type == .connectRequest, let request = message.decode(ConnectRequest.self) else { return }
                transport.send(.accept)
                queue.asyncAfter(deadline: .now() + 1) { transport.close() }
                Task { @MainActor in self?.onConnectRequest?(request) }
            }
            transport.start()
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    self?.startHostListener()
                }
            }
        }
        listener.start(queue: queue)
        hostListener?.cancel()
        hostListener = listener
    }

    private func rebuild() {
        var next: [String: DirectoryEntry] = [:]
        for (id, result) in wifiResults {
            var entry = entries[id] ?? DirectoryEntry(id: id, name: result.name, model: result.model)
            entry.name = entry.info?.name ?? result.name
            entry.wifi = result.endpoint
            entry.usb = nil
            next[id] = entry
        }
        for (mux, owner) in usbOwner {
            guard let device = usbAttached[mux] else { continue }
            var entry = next[owner] ?? entries[owner] ?? DirectoryEntry(id: owner, name: "iPhone", model: "iPhone")
            if next[owner] == nil { entry.wifi = nil }
            if let info = entry.info { entry.name = info.name; entry.model = info.model }
            entry.usb = device
            next[owner] = entry
        }
        for (id, entry) in entries where next[id] == nil {
            var gone = entry
            gone.wifi = nil
            gone.usb = nil
            next[id] = gone
        }
        guard next != entries else { return }
        log.info("directory \(next.values.map { "\($0.name) wifi=\($0.wifi != nil) usb=\($0.usb != nil)" }.joined(separator: ", "), privacy: .public)")
        entries = next
        onChange?()
    }
}
