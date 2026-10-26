import Foundation
import Network

public protocol MessageTransport: AnyObject {
    var onReady: (() -> Void)? { get set }
    var onMessage: ((Message) -> Void)? { get set }
    var onClose: ((Error?) -> Void)? { get set }
    var kind: TransportKind { get }
    var isLoopback: Bool { get }
    func start()
    func send(_ message: Message, completion: (() -> Void)?)
    func close()
}

public extension MessageTransport {
    func send(_ message: Message) { send(message, completion: nil) }
    func send<T: Encodable>(_ type: MessageType, _ value: T) { send(Message(type, json: value), completion: nil) }
    func send(_ type: MessageType) { send(Message(type: type), completion: nil) }
}

public enum NetworkConfig {
    public static func tcp(peerToPeer: Bool = true) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 4
        tcp.connectionTimeout = 6
        tcp.connectionDropTime = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = peerToPeer
        params.serviceClass = .interactiveVideo
        return params
    }
}

public final class NetworkTransport: MessageTransport, @unchecked Sendable {
    public var onReady: (() -> Void)?
    public var onMessage: ((Message) -> Void)?
    public var onClose: ((Error?) -> Void)?
    public let kind: TransportKind
    public let connection: NWConnection
    private let queue: DispatchQueue
    private var parser = MessageParser()
    private var finished = false

    public init(connection: NWConnection, queue: DispatchQueue, kind: TransportKind = .wifi) {
        self.connection = connection
        self.queue = queue
        self.kind = kind
    }

    public var isLoopback: Bool {
        guard case let .hostPort(host, _) = connection.currentPath?.remoteEndpoint ?? connection.endpoint else { return false }
        switch host {
        case let .ipv4(address): return address.isLoopback
        case let .ipv6(address):
            if address.isLoopback { return true }
            if let v4 = address.asIPv4 { return v4.isLoopback }
            return false
        case let .name(name, _): return name == "localhost"
        @unknown default: return false
        }
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.receive()
            case let .failed(error), let .waiting(error):
                self.finish(error)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4 << 20) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                do {
                    for message in try self.parser.append(data) {
                        guard !self.finished else { return }
                        self.onMessage?(message)
                    }
                } catch {
                    self.finish(error)
                    return
                }
            }
            if let error {
                self.finish(error)
            } else if isComplete {
                self.finish(nil)
            } else {
                self.receive()
            }
        }
    }

    public func send(_ message: Message, completion: (() -> Void)?) {
        guard !finished else { return }
        connection.send(content: message.framed(), completion: .contentProcessed { _ in completion?() })
    }

    public func close() {
        guard !finished else { return }
        connection.cancel()
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        connection.cancel()
        let handler = onClose
        onClose = nil
        onMessage = nil
        onReady = nil
        handler?(error)
    }
}

public final class SocketTransport: MessageTransport, @unchecked Sendable {
    public var onReady: (() -> Void)?
    public var onMessage: ((Message) -> Void)?
    public var onClose: ((Error?) -> Void)?
    public let kind: TransportKind
    public let isLoopback = true
    private let queue: DispatchQueue
    private let io: DispatchIO
    private var parser = MessageParser()
    private var finished = false

    public init(fileDescriptor: Int32, queue: DispatchQueue, kind: TransportKind = .usb) {
        self.queue = queue
        self.kind = kind
        self.io = DispatchIO(type: .stream, fileDescriptor: fileDescriptor, queue: queue) { _ in
            Darwin.close(fileDescriptor)
        }
        io.setLimit(lowWater: 1)
        io.setLimit(highWater: 1 << 20)
    }

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.onReady?()
            self.read()
        }
    }

    private func read() {
        io.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                do {
                    for message in try self.parser.append(Data(data)) {
                        guard !self.finished else { return }
                        self.onMessage?(message)
                    }
                } catch {
                    self.finish(error)
                    return
                }
            }
            if error != 0 {
                self.finish(POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO))
            } else if done {
                self.finish(nil)
            }
        }
    }

    public func send(_ message: Message, completion: (() -> Void)?) {
        guard !finished else { return }
        let framed = message.framed()
        let data = framed.withUnsafeBytes { DispatchData(bytes: $0) }
        io.write(offset: 0, data: data, queue: queue) { [weak self] done, _, error in
            if done { completion?() }
            if error != 0 { self?.finish(POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)) }
        }
    }

    public func close() {
        queue.async { [weak self] in self?.finish(nil) }
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        io.close(flags: .stop)
        let handler = onClose
        onClose = nil
        onMessage = nil
        onReady = nil
        handler?(error)
    }
}
