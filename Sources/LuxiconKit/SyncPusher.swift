import Foundation
import Network

public enum SyncPushError: Error, LocalizedError {
    case noListenerFound
    case connectionFailed(String)
    case noAcknowledgement
    case localNetworkDenied(String)

    public var errorDescription: String? {
        switch self {
        case .noListenerFound:
            return "No Mac listener found on this network. Is `luxicon-mcp listen` running?"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason) (check the pairing token)."
        case .noAcknowledgement:
            return "The listener did not confirm the transfer."
        case .localNetworkDenied(let reason):
            return "Local network access was blocked (\(reason)). Check Settings → Privacy & Security → Local Network → Luxicon."
        }
    }
}

extension LuxiconSync {
    /// Discover the first `_luxicon._tcp` listener on the LAN and push one
    /// file to it. Throws when no listener answers within `timeout` — callers
    /// treat that as "Mac not around, try again later".
    /// Push one file to a Mac listener. If `host` is given (e.g. "192.168.1.5"
    /// or "my-mac.local"), connect directly — the reliable path on enterprise
    /// networks that squash mDNS. Otherwise discover via Bonjour.
    public static func push(
        filename: String,
        payload: Data,
        token: String,
        host: String? = nil,
        port: UInt16 = defaultPort,
        timeout: TimeInterval = 8
    ) async throws {
        let endpoint: NWEndpoint
        if let host, !host.isEmpty {
            endpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        } else {
            endpoint = try await withTimeout(timeout, onTimeout: SyncPushError.noListenerFound) {
                try await discoverListener()
            }
        }
        let push = Push(filename: filename, payload: payload)
        try await withTimeout(timeout, onTimeout: SyncPushError.noAcknowledgement) {
            try await send(push, to: endpoint, token: token)
        }
    }

    // MARK: - Internals

    static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        onTimeout: Error,
        _ work: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw onTimeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private static func discoverListener() async throws -> NWEndpoint {
        let browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: nil),
            using: NWParameters())
        let once = Once()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                browser.browseResultsChangedHandler = { results, _ in
                    if let first = results.first {
                        once.run {
                            browser.cancel()
                            continuation.resume(returning: first.endpoint)
                        }
                    }
                }
                browser.stateUpdateHandler = { state in
                    switch state {
                    case .failed(let error):
                        once.run {
                            browser.cancel()
                            continuation.resume(
                                throwing: SyncPushError.connectionFailed("\(error)"))
                        }
                    case .waiting(let error):
                        // Policy denial (Local Network permission off) parks the
                        // browser here forever — fail fast with the real reason.
                        once.run {
                            browser.cancel()
                            continuation.resume(
                                throwing: SyncPushError.localNetworkDenied("\(error)"))
                        }
                    case .cancelled:
                        once.run { continuation.resume(throwing: CancellationError()) }
                    default:
                        break
                    }
                }
                browser.start(queue: .global(qos: .userInitiated))
            }
        } onCancel: {
            // Drives the browser to .cancelled, which resumes the continuation
            // — this is what lets withTimeout's task group actually exit.
            browser.cancel()
        }
    }

    private static func send(_ push: Push, to endpoint: NWEndpoint, token: String) async throws {
        let data = try JSONEncoder().encode(push)
        let connection = NWConnection(to: endpoint, using: parameters(token: token))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PushSender(connection: connection, data: data, continuation: continuation).start()
            }
        } onCancel: {
            // Drives the connection to .cancelled → PushSender resumes the
            // continuation; without this a dead Mac hangs the push forever.
            connection.cancel()
        }
    }
}

/// One outbound push. Callbacks arrive on a single serial queue; the Once
/// guard makes the continuation single-resume regardless.
private final class PushSender: @unchecked Sendable {
    private let connection: NWConnection
    private let data: Data
    private let continuation: CheckedContinuation<Void, Error>
    private let once = Once()
    private let queue = DispatchQueue(label: "luxicon.sync.push")

    init(connection: NWConnection, data: Data, continuation: CheckedContinuation<Void, Error>) {
        self.connection = connection
        self.data = data
        self.continuation = continuation
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                sendPayload()
            case .waiting(let error):
                // .waiting retries indefinitely (host offline, port closed);
                // for a LAN push, failing fast beats hanging until timeout.
                fail("\(error)")
            case .failed(let error):
                fail("\(error)")
            case .cancelled:
                once.run { continuation.resume(throwing: SyncPushError.noAcknowledgement) }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func sendPayload() {
        // Length-prefixed frame — no TLS half-close (which deadlocks the ack).
        connection.send(content: LuxiconSync.frame(data), isComplete: false,
                        completion: .contentProcessed { [self] error in
            if let error { fail("\(error)"); return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { [self] ack, _, _, error in
                if let ack, String(decoding: ack, as: UTF8.self)
                    .hasPrefix(LuxiconSync.ackMessage) {
                    connection.cancel()
                    once.run { continuation.resume() }
                } else {
                    fail(error.map { "\($0)" } ?? "no acknowledgement")
                }
            }
        })
    }

    private func fail(_ reason: String) {
        connection.cancel()
        once.run { continuation.resume(throwing: SyncPushError.connectionFailed(reason)) }
    }
}

/// Resume-exactly-once guard for continuation-based Network callbacks.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}
