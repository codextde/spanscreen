import XCTest
@testable import SpanscreenKit

final class SpanscreenKitTests: XCTestCase {
    func testFramingRoundTripAcrossChunks() throws {
        let messages = [
            Message(.deviceInfo, json: DeviceInfo(deviceID: "A", name: "iPhone", model: "iPhone19,4", appVersion: "1.0", display: DisplayInfo(pixelWidth: 2852, pixelHeight: 2006, scale: 3, pixelsPerInch: 460, maxRefreshRate: 120))),
            Message(type: .frame, payload: VideoFrame(index: 7, isKeyframe: true, captureTime: 123_456, data: Data(repeating: 9, count: 70_000)).encoded()),
            Message(type: .keyframeRequest)
        ]
        let stream = messages.reduce(Data()) { $0 + $1.framed() }
        var parser = MessageParser()
        var received: [Message] = []
        var offset = 0
        for size in [1, 3, 5, 100, 4096, 65_536, 200_000] where offset < stream.count {
            let end = min(stream.count, offset + size)
            received += try parser.append(stream[offset..<end])
            offset = end
        }
        if offset < stream.count { received += try parser.append(stream[offset...]) }

        XCTAssertEqual(received.map(\.type), [.deviceInfo, .frame, .keyframeRequest])
        XCTAssertEqual(received[0].decode(DeviceInfo.self)?.display.pixelWidth, 2852)
        let frame = try XCTUnwrap(VideoFrame(received[1].payload))
        XCTAssertEqual(frame.index, 7)
        XCTAssertTrue(frame.isKeyframe)
        XCTAssertEqual(frame.captureTime, 123_456)
        XCTAssertEqual(frame.data.count, 70_000)
        XCTAssertTrue(received[2].payload.isEmpty)
    }

    func testRejectsOversizedMessage() {
        var parser = MessageParser()
        var header = Data()
        let size = UInt32(Spanscreen.maxMessageSize + 1).bigEndian
        withUnsafeBytes(of: size) { header.append(contentsOf: $0) }
        XCTAssertThrowsError(try parser.append(header))
    }

    func testSkipsUnknownMessageTypes() throws {
        var parser = MessageParser()
        let unknown = Data([0, 0, 0, 2, 250, 1])
        let known = Message(type: .pause).framed()
        let parsed = try parser.append(unknown + known)
        XCTAssertEqual(parsed.map(\.type), [.pause])
    }

    func testInputEventsRoundTrip() {
        let events: [InputEvent] = [
            .pointer(phase: .down, button: .left, x: 0.25, y: 0.75, clickCount: 2),
            .relativeMove(dx: -3.5, dy: 12, dragging: true),
            .click(button: .right, isDown: false, clickCount: 1),
            .scroll(dx: 0, dy: -42.25, phase: .momentum),
            .magnify(amount: 0.1, phase: .changed),
            .keyboard(text: "Grüße"),
            .key(code: 36, modifiers: 1 << 20, isDown: true)
        ]
        for event in events {
            XCTAssertEqual(InputEvent(event.encoded()), event)
        }
        XCTAssertNil(InputEvent(Data([99])))
        XCTAssertNil(InputEvent(Data([1, 0])))
    }

    func testDisplayInfoPhysicalSize() {
        let info = DisplayInfo(pixelWidth: 2853, pixelHeight: 2007, scale: 3, pixelsPerInch: 460, maxRefreshRate: 120)
        XCTAssertEqual(info.physicalSizeMillimeters.width, 157.5, accuracy: 0.1)
        XCTAssertFalse(info.isPortrait)
    }
}

final class PairingTests: XCTestCase {
    func testKeyAgreementAndProofs() throws {
        let host = Pairing.newKeyPair(), device = Pairing.newKeyPair()
        let hostNonce = Pairing.nonce(), deviceNonce = Pairing.nonce()
        let hostKey = try XCTUnwrap(Pairing.deriveKey(privateKey: host, peerPublicKey: device.publicKey.rawRepresentation, hostNonce: hostNonce, deviceNonce: deviceNonce))
        let deviceKey = try XCTUnwrap(Pairing.deriveKey(privateKey: device, peerPublicKey: host.publicKey.rawRepresentation, hostNonce: hostNonce, deviceNonce: deviceNonce))
        XCTAssertEqual(hostKey, deviceKey)
        XCTAssertEqual(hostKey.count, 32)

        let next = (host: Pairing.nonce(), device: Pairing.nonce())
        let proof = Pairing.hostProof(key: hostKey, deviceNonce: next.device, hostNonce: next.host)
        XCTAssertTrue(Pairing.verify(proof, expected: Pairing.hostProof(key: deviceKey, deviceNonce: next.device, hostNonce: next.host)))
        XCTAssertFalse(Pairing.verify(proof, expected: Pairing.deviceProof(key: deviceKey, hostNonce: next.host, deviceNonce: next.device)))
        XCTAssertFalse(Pairing.verify(proof, expected: Pairing.hostProof(key: Data(repeating: 1, count: 32), deviceNonce: next.device, hostNonce: next.host)))
        XCTAssertFalse(Pairing.verify(nil, expected: proof))
    }

    func testStore() {
        let defaults = UserDefaults(suiteName: "spanscreen-tests-\(UUID().uuidString)")!
        let store = PairingStore(defaults: defaults)
        XCTAssertNil(store.key(for: "a"))
        store.setKey(Data([1, 2, 3]), for: "a")
        XCTAssertEqual(store.key(for: "a"), Data([1, 2, 3]))
        store.setKey(nil, for: "a")
        XCTAssertNil(store.key(for: "a"))
    }
}
