import Foundation
import Network
import CryptoKit

/// Device-to-device session sync over the local network.
///
/// Topology: the Mac (`luxicon-mcp listen`) advertises `_luxicon._tcp` via
/// Bonjour; the phone pushes finalized sessions to it. The phone is never a
/// server — iOS suspends backgrounded apps, so pushing at creation time is
/// the only reliable direction.
///
/// Security: TLS with a pre-shared key derived (SHA-256) from a pairing
/// token the Mac generates once and the user enters on the phone. Nothing
/// leaves the LAN; nothing is readable on the wire without the token.
///
/// Wire format: one push per connection — the sender writes a single JSON
/// `Push` document and half-closes; the receiver stores the file, replies
/// `ok`, and closes.
public enum LuxiconSync {
    public static let serviceType = "_luxicon._tcp"
    public static let ackMessage = "ok"
    /// Fixed port so the phone can connect by IP when mDNS is unavailable.
    public static let defaultPort: UInt16 = 51234

    /// One pushed file. `payload` is the standard single-session export
    /// envelope, so the receiver can drop it straight into the library.
    public struct Push: Codable, Sendable {
        public var schemaVersion: Int
        public var filename: String
        public var payload: Data

        public init(filename: String, payload: Data) {
            self.schemaVersion = 1
            self.filename = filename
            self.payload = payload
        }
    }

    /// Strip anything that could escape the library directory.
    public static func sanitizedFilename(_ name: String) -> String {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty || cleaned.hasPrefix(".") ? "session-\(UUID().uuidString)" : cleaned
        return base.hasSuffix(".json") ? base : base + ".json"
    }

    /// TLS-PSK parameters shared by listener and pusher. Both sides must
    /// derive from the same pairing token.
    public static func parameters(token: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = SymmetricKey(data: SHA256.hash(data: Data(token.utf8)))
        let keyData = key.withUnsafeBytes { Data($0) }
        let psk = keyData.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("luxicon-sync".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            tls.securityProtocolOptions, psk as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.includePeerToPeer = true
        return params
    }

    /// Frame a payload as 4-byte big-endian length + bytes. Avoids relying on
    /// TLS half-close (which deadlocks: the sender won't close until it has the
    /// ack, the receiver won't ack until it sees the close).
    public static func frame(_ payload: Data) -> Data {
        var out = Data(count: 4)
        let n = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: n) { out.replaceSubrange(0..<4, with: $0) }
        out.append(payload)
        return out
    }

    /// A reasonable pairing token: 20 base32 characters (~100 bits).
    public static func generateToken() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<20).map { _ in alphabet.randomElement()! })
    }
}
