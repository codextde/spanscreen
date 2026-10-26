import CryptoKit
import Foundation

public enum Pairing {
    public static func nonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    public static func newKeyPair() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    public static func deriveKey(privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublicKey: Data, hostNonce: Data, deviceNonce: Data) -> Data? {
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey),
              let shared = try? privateKey.sharedSecretFromKeyAgreement(with: peer) else { return nil }
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: hostNonce + deviceNonce,
                                                 sharedInfo: Data("spanscreen-pairing-v1".utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    public static func hostProof(key: Data, deviceNonce: Data, hostNonce: Data) -> Data {
        mac(key: key, label: "host", deviceNonce + hostNonce)
    }

    public static func deviceProof(key: Data, hostNonce: Data, deviceNonce: Data) -> Data {
        mac(key: key, label: "device", hostNonce + deviceNonce)
    }

    public static func verify(_ proof: Data?, expected: Data) -> Bool {
        guard let proof, proof.count == expected.count else { return false }
        return zip(proof, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func mac(key: Data, label: String, _ message: Data) -> Data {
        let code = HMAC<SHA256>.authenticationCode(for: Data("spanscreen-\(label)".utf8) + message, using: SymmetricKey(data: key))
        return Data(code)
    }
}

public final class PairingStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private let storageKey = "pairingKeys"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func key(for peerID: String) -> Data? {
        lock.withLock { (defaults.dictionary(forKey: storageKey) as? [String: Data])?[peerID] }
    }

    public func setKey(_ key: Data?, for peerID: String) {
        lock.withLock {
            var all = defaults.dictionary(forKey: storageKey) as? [String: Data] ?? [:]
            all[peerID] = key
            defaults.set(all, forKey: storageKey)
        }
    }
}
