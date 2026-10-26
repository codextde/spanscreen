import Darwin
import Foundation

struct USBDevice: Hashable {
    let muxID: Int
    let serial: String
}

enum USBMuxError: LocalizedError {
    case socket(Int32)
    case refused(Int)
    case protocolError

    var errorDescription: String? {
        switch self {
        case let .socket(code): return "usbmuxd socket error \(code)"
        case let .refused(code): return "The iPhone refused the cable connection (\(code))."
        case .protocolError: return "Unexpected usbmuxd response."
        }
    }
}

final class USBMux: @unchecked Sendable {
    var onAttached: ((USBDevice) -> Void)?
    var onDetached: ((Int) -> Void)?

    private let socketPath = "/var/run/usbmuxd"
    private var listenFD: Int32 = -1
    private var stopped = false
    private var tag: UInt32 = 0
    private let callbackQueue: DispatchQueue

    init(callbackQueue: DispatchQueue = .main) {
        self.callbackQueue = callbackQueue
    }

    func start() {
        stopped = false
        Thread.detachNewThread { [weak self] in self?.listenLoop() }
    }

    func stop() {
        stopped = true
        if listenFD >= 0 { Darwin.shutdown(listenFD, SHUT_RDWR) }
    }

    private func listenLoop() {
        while !stopped {
            guard let fd = try? Self.openSocket(socketPath) else {
                Thread.sleep(forTimeInterval: 3)
                continue
            }
            listenFD = fd
            var attached = Set<Int>()
            let request: [String: Any] = ["MessageType": "Listen", "ClientVersionString": "spanscreen", "ProgName": "Spanscreen", "kLibUSBMuxVersion": 3]
            if (try? Self.write(fd, plist: request, tag: nextTag())) != nil {
                while !stopped, let message = try? Self.read(fd) {
                    switch message["MessageType"] as? String {
                    case "Attached":
                        guard let props = message["Properties"] as? [String: Any],
                              props["ConnectionType"] as? String == "USB",
                              let id = (props["DeviceID"] as? Int) ?? (message["DeviceID"] as? Int) else { continue }
                        let serial = props["SerialNumber"] as? String ?? String(id)
                        attached.insert(id)
                        let device = USBDevice(muxID: id, serial: serial)
                        callbackQueue.async { self.onAttached?(device) }
                    case "Detached":
                        guard let id = message["DeviceID"] as? Int, attached.remove(id) != nil else { continue }
                        callbackQueue.async { self.onDetached?(id) }
                    default:
                        continue
                    }
                }
            }
            Darwin.close(fd)
            listenFD = -1
            for id in attached { callbackQueue.async { self.onDetached?(id) } }
            if !stopped { Thread.sleep(forTimeInterval: 2) }
        }
    }

    private func nextTag() -> UInt32 {
        tag &+= 1
        return tag
    }

    static func connect(device: USBDevice, port: UInt16) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let fd = try openSocket("/var/run/usbmuxd")
                    let swapped = Int((port << 8) | (port >> 8))
                    let request: [String: Any] = ["MessageType": "Connect", "ClientVersionString": "spanscreen", "ProgName": "Spanscreen",
                                                  "kLibUSBMuxVersion": 3, "DeviceID": device.muxID, "PortNumber": swapped]
                    do {
                        try write(fd, plist: request, tag: 1)
                        let response = try read(fd)
                        guard response["MessageType"] as? String == "Result", let number = response["Number"] as? Int else {
                            throw USBMuxError.protocolError
                        }
                        guard number == 0 else { throw USBMuxError.refused(number) }
                        continuation.resume(returning: fd)
                    } catch {
                        Darwin.close(fd)
                        throw error
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func openSocket(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw USBMuxError.socket(errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8.prefix(capacity - 1))
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw USBMuxError.socket(code)
        }
        return fd
    }

    private static func write(_ fd: Int32, plist: [String: Any], tag: UInt32) throws {
        let body = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        var packet = Data()
        for value in [UInt32(16 + body.count), 1, 8, tag] {
            withUnsafeBytes(of: value.littleEndian) { packet.append(contentsOf: $0) }
        }
        packet.append(body)
        try packet.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, raw.baseAddress! + sent, raw.count - sent, 0)
                guard n > 0 else { throw USBMuxError.socket(errno) }
                sent += n
            }
        }
    }

    private static func read(_ fd: Int32) throws -> [String: Any] {
        let header = try readExactly(fd, 16)
        let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard length >= 16, length < 1 << 20 else { throw USBMuxError.protocolError }
        let body = try readExactly(fd, length - 16)
        guard let plist = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else {
            throw USBMuxError.protocolError
        }
        return plist
    }

    private static func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
        var data = Data(count: count)
        var received = 0
        try data.withUnsafeMutableBytes { raw in
            while received < count {
                let n = Darwin.recv(fd, raw.baseAddress! + received, count - received, 0)
                guard n > 0 else { throw USBMuxError.socket(n == 0 ? ECONNRESET : errno) }
                received += n
            }
        }
        return data
    }
}
