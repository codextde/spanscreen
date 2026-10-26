import Network
import QuartzCore
import SpanscreenKit
import SwiftUI
import UIKit

struct LinkStats: Equatable {
    var roundTripMilliseconds: Double = 0
    var latencyMilliseconds: Double = 0
    var framesPerSecond: Double = 0
    var bitrate: Double = 0
}

final class StreamLink: @unchecked Sendable {
    let renderer = VideoRenderer()
    var onControl: ((Message, NetworkTransport) -> Void)?
    var onClosed: ((NetworkTransport, Error?) -> Void)?
    private let lock = NSLock()
    private var activeTransport: NetworkTransport?
    private var open: [ObjectIdentifier: NetworkTransport] = [:]
    private var nonces: [ObjectIdentifier: Data] = [:]
    private var lastPong = Date()
    private var info: DeviceInfo

    init(info: DeviceInfo) {
        self.info = info
        renderer.onNeedsKeyframe = { [weak self] in self?.active?.send(.keyframeRequest) }
    }

    var active: NetworkTransport? {
        get { lock.withLock { activeTransport } }
        set { lock.withLock { activeTransport = newValue } }
    }

    var deviceInfo: DeviceInfo {
        get { lock.withLock { info } }
        set { lock.withLock { info = newValue } }
    }

    func attach(_ transport: NetworkTransport) {
        lock.withLock { open[ObjectIdentifier(transport)] = transport }
        transport.onReady = { [weak self, weak transport] in
            guard let self, let transport else { return }
            var info = self.deviceInfo
            info.busy = self.active != nil
            info.nonce = Pairing.nonce()
            self.lock.withLock { self.nonces[ObjectIdentifier(transport)] = info.nonce }
            transport.send(.deviceInfo, info)
        }
        transport.onMessage = { [weak self, weak transport] message in
            guard let self, let transport else { return }
            self.handle(message, from: transport)
        }
        transport.onClose = { [weak self, weak transport] error in
            guard let self, let transport else { return }
            self.lock.withLock {
                self.open[ObjectIdentifier(transport)] = nil
                self.nonces[ObjectIdentifier(transport)] = nil
            }
            self.onClosed?(transport, error)
        }
        transport.start()
    }

    private func handle(_ message: Message, from transport: NetworkTransport) {
        let isActive = active === transport
        switch message.type {
        case .frame:
            guard isActive, let frame = VideoFrame(message.payload) else { return }
            transport.send(.ack, Ack(frameIndex: frame.index))
            renderer.enqueue(frame)
        case .format:
            guard isActive, let format = message.decode(StreamFormat.self) else { return }
            renderer.setFormat(format)
            onControl?(message, transport)
        case .pong:
            if isActive { heardPong() }
            onControl?(message, transport)
        default:
            onControl?(message, transport)
        }
    }

    func send(_ event: InputEvent) {
        active?.send(Message(type: .input, payload: event.encoded()))
    }

    func nonce(for transport: NetworkTransport) -> Data? {
        lock.withLock { nonces[ObjectIdentifier(transport)] }
    }

    func heardPong() { lock.withLock { lastPong = Date() } }
    var pongSilence: TimeInterval { lock.withLock { Date().timeIntervalSince(lastPong) } }
}

@MainActor
final class ReceiverModel: ObservableObject {
    static let shared = ReceiverModel()

    enum Phase: Equatable {
        case waiting
        case approval(HostHello)
        case connecting(String)
        case streaming
        case reconnecting(String)
    }

    @Published private(set) var phase: Phase = .waiting
    @Published private(set) var session: SessionState?
    @Published private(set) var stats = LinkStats()
    @Published private(set) var serverReady = false
    @Published private(set) var nearbyMacs: [NearbyMac] = []
    @Published private(set) var requestingMacID: String?
    @Published private(set) var videoSize = CGSize.zero
    @Published private(set) var contentRect = CGRect.zero
    @Published var keyboardVisible = false
    @Published private(set) var requestHint: String?

    let link: StreamLink
    let pairings = PairingStore()
    private let settings = AppSettings.shared
    private let server = DisplayServer()
    private let browser = HostBrowser()
    private var activeHello: HostHello?
    private var pending: (transport: NetworkTransport, hello: HostHello)?
    private var requestedHost: (id: String, at: Date)?
    private var pingTimer: Timer?
    private var reconnectTimeout: Task<Void, Never>?
    private var displayUpdate: Task<Void, Never>?
    private var started = false

    var isLive: Bool {
        switch phase {
        case .streaming, .connecting, .reconnecting: return true
        default: return false
        }
    }

    private init() {
        let display = DisplayInfo(pixelWidth: 2, pixelHeight: 2, scale: 3, pixelsPerInch: DeviceIdentity.pixelsPerInch, maxRefreshRate: 60)
        link = StreamLink(info: DeviceInfo(deviceID: DeviceIdentity.deviceID, name: AppSettings.shared.deviceName,
                                           model: DeviceIdentity.modelIdentifier, appVersion: DeviceIdentity.appVersion, display: display))
        link.onControl = { [weak self] message, transport in
            Task { @MainActor in self?.handle(message, from: transport) }
        }
        link.onClosed = { [weak self] transport, _ in
            Task { @MainActor in self?.closed(transport) }
        }
        link.renderer.onFirstFrame = { [weak self] in
            Task { @MainActor in self?.firstFrameShown() }
        }
        server.onConnection = { [weak self] transport in self?.link.attach(transport) }
        server.onState = { [weak self] state in
            Task { @MainActor in self?.serverReady = state == .ready }
        }
        browser.onChange = { [weak self] macs in
            Task { @MainActor in self?.nearbyMacs = macs }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        server.start(name: settings.deviceName)
        browser.start()
    }

    func renamed() {
        var info = link.deviceInfo
        info.name = settings.deviceName
        link.deviceInfo = info
        server.rename(settings.deviceName)
    }

    func sceneBecameActive() {
        server.start(name: settings.deviceName)
        browser.start()
        if let active = link.active {
            active.send(.resume)
            link.renderer.resumeAfterBackground()
        }
    }

    func sceneEnteredBackground() {
        link.active?.send(.pause)
        browser.stop()
    }

    func updateGeometry(bounds: CGRect, safeArea: UIEdgeInsets, scale: CGFloat, maxRefreshRate: Int) {
        var insets = settings.edgeToEdge ? .zero : safeArea
        insets.bottom = 0
        if bounds.width > bounds.height { insets.top = 0 }
        let rect = bounds.inset(by: insets)
        guard rect.width > 10, rect.height > 10 else { return }
        if rect != contentRect { contentRect = rect }
        let display = DisplayInfo(pixelWidth: Int(rect.width * scale) & ~1, pixelHeight: Int(rect.height * scale) & ~1, scale: Double(scale),
                                  pixelsPerInch: DeviceIdentity.pixelsPerInch, maxRefreshRate: maxRefreshRate)
        var info = link.deviceInfo
        guard info.display != display else { return }
        info.display = display
        link.deviceInfo = info
        displayUpdate?.cancel()
        displayUpdate = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.link.active?.send(.display, self.link.deviceInfo.display)
        }
    }

    private func handle(_ message: Message, from transport: NetworkTransport) {
        switch message.type {
        case .hostHello:
            guard let hello = message.decode(HostHello.self) else { return }
            received(hello, on: transport)
        case .format:
            guard transport === link.active, let format = message.decode(StreamFormat.self) else { return }
            videoSize = CGSize(width: format.width, height: format.height)
        case .session:
            guard transport === link.active, let state = message.decode(SessionState.self) else { return }
            session = state
        case .pong:
            guard transport === link.active, let pong = message.decode(Ping.self) else { return }
            stats = LinkStats(roundTripMilliseconds: CACurrentMediaTime() * 1000 - pong.sentAt,
                              latencyMilliseconds: pong.latencyMilliseconds ?? 0,
                              framesPerSecond: pong.framesPerSecond ?? 0,
                              bitrate: pong.bitrate ?? 0)
        case .bye:
            guard transport === link.active else { return }
            transport.close()
            endSession()
        default:
            break
        }
    }

    private func received(_ hello: HostHello, on transport: NetworkTransport) {
        guard hello.protocolVersion == Spanscreen.protocolVersion else {
            transport.send(.decline, Decline(reason: .incompatible))
            transport.close()
            return
        }
        guard hello.intent == .connect else { return }
        if let activeHello, link.active != nil, activeHello.hostID != hello.hostID {
            transport.send(.decline, Decline(reason: .busy))
            transport.close()
            return
        }
        let requested = requestedHost.map { $0.id == hello.hostID && Date().timeIntervalSince($0.at) < 90 } ?? false
        if let key = pairings.key(for: hello.hostID), let nonce = link.nonce(for: transport),
           Pairing.verify(hello.proof, expected: Pairing.hostProof(key: key, deviceNonce: nonce, hostNonce: hello.nonce)) {
            accept(transport, hello, pair: false)
        } else if transport.isLoopback || (hello.requestedByDevice && requested) {
            accept(transport, hello, pair: true)
        } else {
            if let pending { pending.transport.close() }
            pending = (transport, hello)
            phase = .approval(hello)
        }
    }

    func approve(_ allow: Bool) {
        guard let pending else { return }
        self.pending = nil
        if allow {
            accept(pending.transport, pending.hello, pair: true)
        } else {
            pending.transport.send(.decline, Decline(reason: .userDeclined))
            pending.transport.close()
            phase = link.active == nil ? .waiting : .streaming
        }
    }

    private func accept(_ transport: NetworkTransport, _ hello: HostHello, pair: Bool) {
        guard let nonce = link.nonce(for: transport) else {
            transport.close()
            return
        }
        var acceptInfo = AcceptInfo()
        if pair {
            let privateKey = Pairing.newKeyPair()
            guard let key = Pairing.deriveKey(privateKey: privateKey, peerPublicKey: hello.publicKey, hostNonce: hello.nonce, deviceNonce: nonce) else {
                transport.close()
                return
            }
            pairings.setKey(key, for: hello.hostID)
            acceptInfo.publicKey = privateKey.publicKey.rawRepresentation
        } else if let key = pairings.key(for: hello.hostID) {
            acceptInfo.proof = Pairing.deviceProof(key: key, hostNonce: hello.nonce, deviceNonce: nonce)
        }
        settings.trust(hello)
        reconnectTimeout?.cancel()
        let previous = link.active
        link.active = transport
        activeHello = hello
        previous?.close()
        requestedHost = nil
        requestingMacID = nil
        requestHint = nil
        transport.send(.accept, acceptInfo)
        transport.send(.display, link.deviceInfo.display)
        if phase != .streaming { phase = .connecting(hello.name) }
        link.renderer.armFirstFrame()
        UIApplication.shared.isIdleTimerDisabled = true
        startPing()
    }

    private func firstFrameShown() {
        guard link.active != nil else { return }
        withAnimation(.easeOut(duration: 0.35)) { phase = .streaming }
    }

    private func closed(_ transport: NetworkTransport) {
        if pending?.transport === transport {
            pending = nil
            if case .approval = phase { phase = link.active == nil ? .waiting : .streaming }
            return
        }
        guard transport === link.active else { return }
        link.active = nil
        pingTimer?.invalidate()
        guard phase != .waiting else { return }
        phase = .reconnecting(activeHello?.name ?? "Mac")
        reconnectTimeout?.cancel()
        reconnectTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.link.active == nil else { return }
            self.endSession()
        }
    }

    func disconnect() {
        if let active = link.active {
            active.send(Message(type: .bye)) { [weak active] in active?.close() }
        }
        endSession()
    }

    private func endSession() {
        reconnectTimeout?.cancel()
        pingTimer?.invalidate()
        link.active = nil
        activeHello = nil
        session = nil
        stats = LinkStats()
        videoSize = .zero
        keyboardVisible = false
        link.renderer.reset()
        UIApplication.shared.isIdleTimerDisabled = false
        withAnimation(.easeInOut(duration: 0.3)) { phase = .waiting }
    }

    func setOptions(_ change: (inout SessionOptions) -> Void) {
        guard var options = session?.options else { return }
        change(&options)
        session?.options = options
        link.active?.send(.setOptions, options)
    }

    func request(_ mac: NearbyMac) {
        requestingMacID = mac.id
        requestHint = nil
        requestedHost = (mac.id, Date())
        browser.request(mac, name: settings.deviceName) { [weak self] ok in
            guard let self else { return }
            if !ok, self.requestingMacID == mac.id { self.requestingMacID = nil }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                if self.requestingMacID == mac.id, !self.isLive {
                    self.requestingMacID = nil
                    if ok { self.requestHint = mac.name }
                }
            }
        }
    }

    func send(_ event: InputEvent) {
        link.send(event)
    }

    #if DEBUG
    func startDemo(videoSize: CGSize, macs: Bool) {
        if macs {
            nearbyMacs = [NearbyMac(id: "demo", name: "MacBook Pro", endpoint: .hostPort(host: "127.0.0.1", port: 1))]
            serverReady = true
            if UserDefaults.standard.bool(forKey: "demoApproval") {
                phase = .approval(HostHello(hostID: "demo", name: "MacBook Pro", model: "Mac16,8", appVersion: "1.0.0", intent: .connect))
            }
            return
        }
        self.videoSize = videoSize
        session = SessionState(hostName: "MacBook Pro", options: SessionOptions(), transport: .usb, canUseHighRefreshRate: true)
        stats = LinkStats(roundTripMilliseconds: 2, latencyMilliseconds: 8, framesPerSecond: 120, bitrate: 31_000_000)
        phase = .streaming
    }
    #endif

    private func startPing() {
        pingTimer?.invalidate()
        link.heardPong()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let active = self.link.active else { return }
                if self.link.pongSilence > 6 {
                    active.close()
                    return
                }
                active.send(.ping, Ping(sentAt: CACurrentMediaTime() * 1000))
            }
        }
    }
}
