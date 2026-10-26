import AppKit
import CryptoKit
import Foundation
import Network
import OSLog
import SpanscreenKit

let log = Logger(subsystem: "de.codext.spanscreen", category: "session")

@MainActor
final class HostSession: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case connecting
        case awaitingApproval
        case starting
        case streaming
        case paused
        case reconnecting
        case failed(String)
        case ended

        var isLive: Bool {
            switch self {
            case .starting, .streaming, .paused, .reconnecting: return true
            default: return false
            }
        }
    }

    static let pairings = PairingStore()

    let id: String
    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var device: DeviceInfo?
    @Published private(set) var transportKind: TransportKind = .wifi
    @Published private(set) var options: SessionOptions
    @Published private(set) var stats = StreamStats()
    @Published private(set) var position: DisplayPosition?
    private(set) var endedByDevice = false

    var routeProvider: (() -> Route?)?
    var onEnded: ((HostSession) -> Void)?
    var onAccepted: ((DeviceInfo, SessionOptions) -> Void)?

    private struct Handshake {
        let transport: MessageTransport
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        let hostNonce: Data
        var deviceNonce: Data?
    }

    private var transport: MessageTransport?
    private var pending: Handshake?
    private let pipeline = StreamPipeline()
    private let injector = InputInjector()
    private let statsBox = StatsBox()
    private let link = LinkBox()
    private var display: VirtualDisplay?
    private var streamStarted = false
    private var userEnded = false
    private var tornDown = false
    private var reconnectTask: Task<Void, Never>?
    private var reconfigureTask: Task<Void, Never>?
    private var watchdog: Timer?
    private let requestedByDevice: Bool
    private let userInitiated: Bool
    private let queue = DispatchQueue(label: "de.codext.spanscreen.session", qos: .userInteractive)
    private var screenObserver: NSObjectProtocol?
    private var configuring = false
    private var needsReconfigure = false

    init(deviceID: String, name: String, options: SessionOptions, requestedByDevice: Bool, userInitiated: Bool) {
        id = deviceID
        self.options = options
        self.requestedByDevice = requestedByDevice
        self.userInitiated = userInitiated
        pipeline.onStats = { [weak self, statsBox] stats in
            statsBox.value = stats
            Task { @MainActor in self?.stats = stats }
        }
        pipeline.onCaptureStopped = { [weak self] error in
            Task { @MainActor in self?.captureStopped(error) }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshBounds() }
        }
    }

    var name: String { device?.name ?? "iPhone" }

    func connect(_ route: Route) {
        Task { await open(route) }
    }

    private func open(_ route: Route) async {
        guard !userEnded else { return }
        if transport == nil, phase != .reconnecting { phase = .connecting }
        do {
            let t: MessageTransport
            switch route {
            case let .usb(device):
                let fd = try await USBMux.connect(device: device, port: Spanscreen.devicePort)
                t = SocketTransport(fileDescriptor: fd, queue: queue)
            case let .wifi(endpoint):
                t = NetworkTransport(connection: NWConnection(to: endpoint, using: NetworkConfig.tcp()), queue: queue, kind: .wifi)
            }
            guard !userEnded else { t.close(); return }
            log.info("opening \(route.kind.rawValue, privacy: .public) transport to \(self.id, privacy: .public)")
            pending?.transport.close()
            pending = Handshake(transport: t, privateKey: Pairing.newKeyPair(), hostNonce: Pairing.nonce())
            attach(t)
            t.start()
        } catch {
            if transport == nil, phase != .reconnecting {
                fail(error.localizedDescription)
            }
        }
    }

    private func attach(_ t: MessageTransport) {
        let injector = injector, pipeline = pipeline, statsBox = statsBox, link = link
        let token = ObjectIdentifier(t)
        t.onMessage = { [weak self] message in
            let isActive = link.isActive(token)
            if isActive { link.heard() }
            switch message.type {
            case .input:
                if isActive, let event = InputEvent(message.payload) { injector.handle(event) }
            case .ack:
                if isActive, let ack = message.decode(Ack.self) { pipeline.acknowledge(ack.frameIndex) }
            case .ping:
                if isActive, let ping = message.decode(Ping.self) {
                    let s = statsBox.value
                    t.send(.pong, Ping(sentAt: ping.sentAt, latencyMilliseconds: s.latencyMilliseconds, bitrate: s.bitrate, framesPerSecond: s.framesPerSecond))
                }
            default:
                Task { @MainActor in self?.handle(message, from: t) }
            }
        }
        t.onClose = { [weak self] error in
            Task { @MainActor in self?.closed(t, error: error) }
        }
    }

    private func handle(_ message: Message, from t: MessageTransport) {
        let isPending = pending?.transport === t
        guard t === transport || isPending else { return }
        switch message.type {
        case .deviceInfo:
            guard let info = message.decode(DeviceInfo.self) else { return }
            guard info.protocolVersion == Spanscreen.protocolVersion else {
                fail("Update Spanscreen on your Mac and iPhone to the same version.")
                return
            }
            guard info.deviceID == id else {
                t.close()
                return
            }
            if isPending, pending?.deviceNonce == nil {
                pending?.deviceNonce = info.nonce
                sendHello(on: t)
                if transport == nil, phase == .connecting { phase = .awaitingApproval }
            }
            let displayChanged = device?.display != info.display
            device = info
            if displayChanged, t === transport { scheduleReconfigure() }
        case .accept:
            guard isPending, let handshake = pending, let deviceNonce = handshake.deviceNonce else { return }
            let accept = message.decode(AcceptInfo.self) ?? AcceptInfo()
            if let publicKey = accept.publicKey {
                guard userInitiated || t.kind == .usb else {
                    pairingFailed(t)
                    return
                }
                guard let key = Pairing.deriveKey(privateKey: handshake.privateKey, peerPublicKey: publicKey, hostNonce: handshake.hostNonce, deviceNonce: deviceNonce) else {
                    pairingFailed(t)
                    return
                }
                Self.pairings.setKey(key, for: id)
            } else {
                guard let key = Self.pairings.key(for: id),
                      Pairing.verify(accept.proof, expected: Pairing.deviceProof(key: key, hostNonce: handshake.hostNonce, deviceNonce: deviceNonce)) else {
                    pairingFailed(t)
                    return
                }
            }
            promote(t)
        case .decline:
            guard isPending else { return }
            pending = nil
            t.close()
            if transport == nil {
                let reason = message.decode(Decline.self)?.reason
                fail(reason == .busy ? "\(name) is already in use by another Mac." : "\(name) declined the connection.")
            }
        case .display:
            guard t === transport, let info = message.decode(DisplayInfo.self), device?.display != info else { return }
            device?.display = info
            scheduleReconfigure()
        case .keyframeRequest:
            if t === transport { pipeline.requestKeyframe() }
        case .setOptions:
            if t === transport, let options = message.decode(SessionOptions.self) { update(options) }
        case .pause:
            guard t === transport else { return }
            pipeline.pause()
            if phase == .streaming { phase = .paused }
        case .resume:
            guard t === transport else { return }
            pipeline.resume()
            if phase == .paused { phase = .streaming }
        case .bye:
            guard t === transport else { return }
            endedByDevice = true
            userEnded = true
            Task { await teardown() }
        default:
            break
        }
    }

    private func sendHello(on t: MessageTransport) {
        guard let handshake = pending, handshake.transport === t, let deviceNonce = handshake.deviceNonce else { return }
        var hello = HostIdentity.shared.hello(.connect, requestedByDevice: requestedByDevice)
        hello.nonce = handshake.hostNonce
        hello.publicKey = handshake.privateKey.publicKey.rawRepresentation
        if let key = Self.pairings.key(for: id) {
            hello.proof = Pairing.hostProof(key: key, deviceNonce: deviceNonce, hostNonce: handshake.hostNonce)
        }
        t.send(.hostHello, hello)
    }

    private func pairingFailed(_ t: MessageTransport) {
        pending = nil
        t.close()
        if transport == nil {
            fail("\(name) could not be verified. Click Connect to pair it again.")
        }
    }

    private func promote(_ t: MessageTransport) {
        log.info("accepted over \(t.kind.rawValue, privacy: .public)")
        pending = nil
        injector.releaseAll()
        let old = transport
        transport = t
        transportKind = t.kind
        link.activate(ObjectIdentifier(t))
        old?.close()
        reconnectTask?.cancel()
        reconnectTask = nil
        pipeline.setTransport(t)
        startWatchdog()
        if let device { onAccepted?(device, options) }
        if streamStarted {
            pipeline.resume()
            sendState()
            phase = .streaming
            scheduleReconfigure()
        } else {
            Task { await startStreaming() }
        }
    }

    private func closed(_ t: MessageTransport, error: Error?) {
        if pending?.transport === t {
            pending = nil
            if transport == nil, phase != .reconnecting, !userEnded {
                fail(error.map { "Could not connect: \($0.localizedDescription)" } ?? "\(name) closed the connection.")
            }
            return
        }
        guard t === transport else { return }
        transport = nil
        link.activate(nil)
        injector.releaseAll()
        pipeline.setTransport(nil)
        guard !tornDown else { return }
        if case .failed = phase { return }
        if userEnded || !phase.isLive {
            Task { await teardown() }
            return
        }
        phase = .reconnecting
        pipeline.pause()
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(30)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self, self.transport == nil, !self.userEnded, !Task.isCancelled else { return }
                if self.pending == nil, let route = self.routeProvider?() { await self.open(route) }
            }
            guard let self, !Task.isCancelled, self.transport == nil else { return }
            await self.teardown()
        }
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        link.heard()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let transport = self.transport else { return }
                if self.link.silence > 6 {
                    log.info("link silent, closing")
                    transport.close()
                }
            }
        }
    }

    func upgrade(to route: Route) {
        guard transport != nil, pending == nil, route.kind != transportKind else { return }
        connect(route)
    }

    func disconnect() {
        userEnded = true
        reconnectTask?.cancel()
        if let transport {
            transport.send(Message(type: .bye)) { [weak transport] in transport?.close() }
        }
        pending?.transport.close()
        Task { await teardown() }
    }

    func update(_ newOptions: SessionOptions) {
        guard newOptions != options else { sendState(); return }
        options = newOptions
        scheduleReconfigure(immediately: true)
    }

    func place(_ newPosition: DisplayPosition) {
        display?.place(newPosition)
        position = display?.currentPosition
        refreshBounds()
    }

    private func scheduleReconfigure(immediately: Bool = false) {
        reconfigureTask?.cancel()
        reconfigureTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(immediately ? 60 : 200))
            guard !Task.isCancelled, let self, self.transport != nil else { return }
            Task { await self.startStreaming() }
        }
    }

    private struct Plan {
        var points: CGSize
        var pixels: CGSize
        var framesPerSecond: Int
        var bitrate: Int
        var maxBitrate: Int
    }

    private func plan(for info: DisplayInfo) -> Plan {
        let width = max(2, info.pixelWidth & ~1)
        let height = max(2, info.pixelHeight & ~1)
        let ppp = options.textSize.pixelsPerPoint
        let points = CGSize(width: (Double(width) / ppp).rounded(), height: (Double(height) / ppp).rounded())
        let fps = options.highRefreshRate && info.maxRefreshRate >= 120 ? 120 : 60
        let bitrate = Int(Double(width * height * fps) * options.quality.bitsPerPixelFrame)
        let maxBitrate = transportKind == .usb ? 160_000_000 : 45_000_000
        return Plan(points: points, pixels: CGSize(width: width, height: height), framesPerSecond: fps,
                    bitrate: max(4_000_000, bitrate), maxBitrate: maxBitrate)
    }

    private var isActive: Bool { !userEnded && !tornDown && transport != nil }

    private func startStreaming() async {
        guard let info = device?.display, isActive else { return }
        if configuring {
            needsReconfigure = true
            return
        }
        configuring = true
        defer {
            configuring = false
            if needsReconfigure, isActive {
                needsReconfigure = false
                scheduleReconfigure(immediately: true)
            }
        }
        if phase != .streaming { phase = .starting }
        let plan = plan(for: info)
        do {
            let capture: ScreenCapturer.Configuration
            switch options.mode {
            case .extend:
                let display = try ensureDisplay(plan: plan, info: info)
                let configured = await display.configure(points: plan.points, refreshRate: Double(plan.framesPerSecond))
                guard isActive else { return }
                guard configured else {
                    throw NSError(domain: "Spanscreen", code: 2, userInfo: [NSLocalizedDescriptionKey: "macOS did not accept the display mode."])
                }
                capture = .init(displayID: display.displayID, width: Int(plan.pixels.width), height: Int(plan.pixels.height), framesPerSecond: plan.framesPerSecond)
                position = display.currentPosition
            case .mirror:
                display = nil
                position = nil
                let main = CGMainDisplayID()
                let size = Self.fit(CGDisplayBounds(main).size, into: plan.pixels)
                capture = .init(displayID: main, width: Int(size.width), height: Int(size.height), framesPerSecond: plan.framesPerSecond)
            }
            refreshBounds()
            log.info("streaming \(capture.width)x\(capture.height)@\(capture.framesPerSecond) display \(capture.displayID) mode \(self.options.mode.rawValue, privacy: .public)")
            try await pipeline.start(capture: capture, targetBitrate: plan.bitrate, maxBitrate: plan.maxBitrate)
            guard isActive else {
                await pipeline.stop()
                return
            }
            streamStarted = true
            sendState()
            phase = .streaming
        } catch {
            guard isActive else { return }
            fail(error.localizedDescription)
        }
    }

    private func ensureDisplay(plan: Plan, info: DisplayInfo) throws -> VirtualDisplay {
        if let display, display.fits(points: plan.points) { return display }
        display = nil
        let mm = info.physicalSizeMillimeters
        let maxSide = max(Double(max(info.pixelWidth, info.pixelHeight)), 2880)
        let maxPixels = (Int(maxSide * 2 / TextSize.mostSpace.pixelsPerPoint) + 15) & ~15
        guard let created = VirtualDisplay(name: name, serial: VirtualDisplay.serial(for: id),
                                           sizeInMillimeters: CGSize(width: mm.width, height: mm.height), maxPixels: maxPixels) else {
            throw NSError(domain: "Spanscreen", code: 3, userInfo: [NSLocalizedDescriptionKey: "macOS could not create the virtual display."])
        }
        display = created
        return created
    }

    private static func fit(_ source: CGSize, into box: CGSize) -> CGSize {
        let aspect = source.width / max(source.height, 1)
        var size = box
        if box.width / box.height > aspect {
            size.width = (box.height * aspect).rounded()
        } else {
            size.height = (box.width / aspect).rounded()
        }
        return CGSize(width: max(2, Int(size.width) & ~1), height: max(2, Int(size.height) & ~1))
    }

    private func refreshBounds() {
        switch options.mode {
        case .extend: injector.targetBounds = display?.bounds ?? .zero
        case .mirror: injector.targetBounds = CGDisplayBounds(CGMainDisplayID())
        }
        position = display?.currentPosition
    }

    private func sendState() {
        let canHigh = (device?.display.maxRefreshRate ?? 60) >= 120
        transport?.send(.session, SessionState(hostName: HostIdentity.shared.name, options: options, transport: transportKind, canUseHighRefreshRate: canHigh))
    }

    private func captureStopped(_ error: Error?) {
        guard phase.isLive, isActive else { return }
        streamStarted = false
        scheduleReconfigure()
    }

    private func fail(_ message: String) {
        guard !tornDown else { return }
        log.error("session failed: \(message, privacy: .public)")
        phase = .failed(message)
        userEnded = true
        transport?.close()
        pending?.transport.close()
        Task { await teardown(keepPhase: true) }
    }

    private func teardown(keepPhase: Bool = false) async {
        guard !tornDown else { return }
        tornDown = true
        reconnectTask?.cancel()
        reconfigureTask?.cancel()
        watchdog?.invalidate()
        watchdog = nil
        link.activate(nil)
        injector.releaseAll()
        await pipeline.stop()
        display = nil
        position = nil
        transport = nil
        pending = nil
        streamStarted = false
        if !keepPhase { phase = .ended }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        onEnded?(self)
    }
}

#if DEBUG
extension HostSession {
    func applyDemo(device: DeviceInfo, transport: TransportKind) {
        self.device = device
        transportKind = transport
        phase = .streaming
        position = .right
        stats = StreamStats(latencyMilliseconds: 7, bitrate: 28_000_000, framesPerSecond: 120)
    }
}
#endif

final class StatsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stats = StreamStats()
    var value: StreamStats {
        get { lock.withLock { stats } }
        set { lock.withLock { stats = newValue } }
    }
}

final class LinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var active: ObjectIdentifier?
    private var lastHeard = Date()

    func activate(_ id: ObjectIdentifier?) {
        lock.withLock {
            active = id
            lastHeard = Date()
        }
    }

    func isActive(_ id: ObjectIdentifier) -> Bool { lock.withLock { active == id } }
    func heard() { lock.withLock { lastHeard = Date() } }
    var silence: TimeInterval { lock.withLock { Date().timeIntervalSince(lastHeard) } }
}
