import Foundation
import Network
import LuxiconKit

/// `luxicon-mcp listen` — receives sessions pushed from the Luxicon iPhone
/// app over the local network and writes them into the library folder.
///
/// Advertises `_luxicon._tcp` via Bonjour; connections are TLS-PSK using a
/// pairing token generated on first run (stored beside the library at
/// `.sync-token`, printed for entry on the phone). Same-named pushes
/// overwrite, so re-pushing a session after its summary lands is idempotent.
enum SyncListener {
    static func run(libraryURL: URL) throws -> Never {
        try FileManager.default.createDirectory(
            at: libraryURL, withIntermediateDirectories: true)
        let token = try loadOrCreateToken(libraryURL: libraryURL)

        let listener = try NWListener(
            using: LuxiconSync.parameters(token: token),
            on: NWEndpoint.Port(rawValue: LuxiconSync.defaultPort)!)
        let deviceName = Host.current().localizedName ?? "Mac"
        listener.service = NWListener.Service(
            name: deviceName, type: LuxiconSync.serviceType)

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let port = listener.port.map(String.init(describing:)) ?? "?"
                print("""
                Luxicon sync listener ready on port \(port), advertising as "\(deviceName)".
                Library: \(libraryURL.path)

                Pairing token (enter in Luxicon → My Voice → Mac Sync):

                    \(token)

                If the phone can't find this Mac automatically (enterprise Wi-Fi
                often blocks mDNS), enter one of these addresses manually:

                \(Self.localAddresses().map { "    \($0):\(LuxiconSync.defaultPort)" }.joined(separator: "\n"))

                Waiting for pushes… (Ctrl-C to stop)
                """)
            case .failed(let error):
                FileHandle.standardError.write(Data("Listener failed: \(error)\n".utf8))
                exit(1)
            default:
                break
            }
        }
        listener.newConnectionHandler = { connection in
            handle(connection, libraryURL: libraryURL)
        }
        listener.start(queue: .main)
        dispatchMain()
    }

    /// Non-loopback IPv4 addresses, for manual pairing when mDNS is blocked.
    static func localAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ptr.pointee.ifa_addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let addr = String(cString: host)
                if !addr.hasPrefix("169.254") { addresses.append(addr) }  // skip link-local
            }
        }
        return addresses.isEmpty ? ["<this Mac's IP>"] : addresses
    }

    static func loadOrCreateToken(libraryURL: URL) throws -> String {
        let tokenURL = libraryURL.appendingPathComponent(".sync-token")
        if let existing = try? String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            return existing
        }
        let token = LuxiconSync.generateToken()
        try token.write(to: tokenURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        return token
    }

    private static func handle(_ connection: NWConnection, libraryURL: URL) {
        PushReceiver(connection: connection, libraryURL: libraryURL).start()
    }
}

/// One inbound push. All callbacks arrive on the connection's serial queue
/// (`.main`), so unsynchronized state is safe despite Sendable conformance.
private final class PushReceiver: @unchecked Sendable {
    private let connection: NWConnection
    private let libraryURL: URL
    private var received = Data()

    init(connection: NWConnection, libraryURL: URL) {
        self.connection = connection
        self.libraryURL = libraryURL
    }

    func start() {
        connection.start(queue: .main)
        readLength()
    }

    /// Read the 4-byte big-endian length prefix, then exactly that many bytes.
    private var expected = 0

    private func readLength() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [self] data, _, _, error in
            guard let data, data.count == 4, error == nil else {
                if let error { print("Length read failed: \(error)") }
                connection.cancel(); return
            }
            expected = data.withUnsafeBytes { Int($0.load(as: UInt32.self).bigEndian) }
            readBody()
        }
    }

    private func readBody() {
        let remaining = expected - received.count
        guard remaining > 0 else { store(received); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [self] data, _, _, error in
            if let data { received.append(data) }
            if let error { print("Body read failed: \(error)"); connection.cancel(); return }
            if received.count >= expected { store(received) } else { readBody() }
        }
    }

    private func store(_ data: Data) {
        guard let push = try? JSONDecoder().decode(LuxiconSync.Push.self, from: data) else {
            print("Rejected push: unrecognized payload (\(data.count) bytes)")
            connection.cancel()
            return
        }
        let filename = LuxiconSync.sanitizedFilename(push.filename)
        do {
            try push.payload.write(to: libraryURL.appendingPathComponent(filename))
            print("Received \(filename) (\(push.payload.count) bytes)")
            connection.send(
                content: Data(LuxiconSync.ackMessage.utf8),
                completion: .contentProcessed { [self] _ in connection.cancel() })
        } catch {
            print("Write failed for \(filename): \(error)")
            connection.cancel()
        }
    }
}
