import Foundation
import Network
import SpanscreenKit

final class DisplayServer: @unchecked Sendable {
    enum State: Equatable {
        case stopped
        case starting
        case ready
        case failed(String)
    }

    var onConnection: ((NetworkTransport) -> Void)?
    var onState: ((State) -> Void)?
    let queue = DispatchQueue(label: "de.codext.spanscreen.network", qos: .userInteractive)
    private var listener: NWListener?
    private var name = ""
    private var restartWork: DispatchWorkItem?
    private var useFixedPort = true
    private var fixedPortFailures = 0

    func start(name: String) {
        queue.async {
            self.name = name
            if let listener = self.listener {
                switch listener.state {
                case .setup, .ready, .waiting: return
                default: break
                }
            }
            self.startListener()
        }
    }

    func rename(_ name: String) {
        queue.async {
            guard name != self.name else { return }
            self.name = name
            self.listener?.service = self.service()
        }
    }

    func stop() {
        queue.async {
            self.restartWork?.cancel()
            self.listener?.cancel()
            self.listener = nil
            self.onState?(.stopped)
        }
    }

    private func service() -> NWListener.Service {
        var txt = NWTXTRecord()
        txt["id"] = DeviceIdentity.deviceID
        txt["model"] = DeviceIdentity.modelIdentifier
        txt["v"] = String(Spanscreen.protocolVersion)
        return NWListener.Service(name: name, type: Spanscreen.displayServiceType, txtRecord: txt)
    }

    private func startListener() {
        listener?.cancel()
        listener = nil
        onState?(.starting)
        let parameters = NetworkConfig.tcp(peerToPeer: true)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            if useFixedPort, let port = NWEndpoint.Port(rawValue: Spanscreen.devicePort) {
                listener = try NWListener(using: parameters, on: port)
            } else {
                listener = try NWListener(using: parameters)
            }
        } catch {
            fixedPortFailures += 1
            useFixedPort = fixedPortFailures < 4
            scheduleRestart()
            return
        }
        listener.service = service()
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.onConnection?(NetworkTransport(connection: connection, queue: self.queue))
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener, listener === self.listener else { return }
            switch state {
            case .ready:
                if listener.port?.rawValue == Spanscreen.devicePort { self.fixedPortFailures = 0 }
                self.onState?(.ready)
            case let .failed(error):
                if case let .posix(code) = error, code == .EADDRINUSE {
                    self.fixedPortFailures += 1
                    self.useFixedPort = self.fixedPortFailures < 4
                }
                self.onState?(.failed(error.localizedDescription))
                self.scheduleRestart()
            case let .waiting(error):
                self.onState?(.failed(error.localizedDescription))
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func scheduleRestart() {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startListener() }
        restartWork = work
        queue.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

struct NearbyMac: Identifiable, Equatable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
}

final class HostBrowser: @unchecked Sendable {
    var onChange: (([NearbyMac]) -> Void)?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "de.codext.spanscreen.browser")

    func start() {
        stop()
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Spanscreen.hostServiceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let macs = results.compactMap { result -> NearbyMac? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                var id = name
                if case let .bonjour(txt) = result.metadata, let value = txt["id"] { id = value }
                return NearbyMac(id: id, name: name, endpoint: result.endpoint)
            }
            var unique: [String: NearbyMac] = [:]
            for mac in macs { unique[mac.id] = mac }
            self?.onChange?(unique.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    func request(_ mac: NearbyMac, name: String, completion: @escaping (Bool) -> Void) {
        let transport = NetworkTransport(connection: NWConnection(to: mac.endpoint, using: NetworkConfig.tcp()), queue: queue)
        var finished = false
        let finish: (Bool) -> Void = { ok in
            guard !finished else { return }
            finished = true
            transport.close()
            DispatchQueue.main.async { completion(ok) }
        }
        transport.onReady = {
            transport.send(.connectRequest, ConnectRequest(deviceID: DeviceIdentity.deviceID, name: name))
        }
        transport.onMessage = { message in
            if message.type == .accept { finish(true) }
        }
        transport.onClose = { _ in finish(false) }
        transport.start()
        queue.asyncAfter(deadline: .now() + 6) { finish(false) }
    }
}
