import Foundation
import Observation
import LuxiconKit
#if os(iOS)
import UIKit
#endif

/// Live caption preview while recording. Best-effort: if the streaming model
/// isn't available (still downloading, load failure), recording proceeds
/// without captions. The final diarized transcript comes from MeetingPipeline.
@Observable @MainActor
final class LiveCaptioner {
    enum Status: Equatable {
        case idle
        case loading(String)
        case live
        case unavailable
    }

    private(set) var status: Status = .idle
    private(set) var committed = ""
    private(set) var partial = ""
    /// Whole caption text to render.
    var text: String { committed + partial }

    /// Audio-thread-safe funnel into the async pump.
    private let sink = SampleSink()
    private var pumpTask: Task<Void, Never>?
    // Written once in init, read in deinit (nonisolated in Swift 6); the
    // observer closures capture only the thread-safe sink.
    nonisolated(unsafe) private var lifecycleObservers: [NSObjectProtocol] = []

    init() {
        #if os(iOS)
        // Caption inference is CoreML; GPU work from a backgrounded app gets the
        // process killed. Drop samples while backgrounded — recording itself is
        // unaffected and the final transcript uses the full audio file.
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: .main
            ) { [sink] _ in sink.suspended = true },
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil, queue: .main
            ) { [sink] _ in sink.suspended = false },
        ]
        #endif
    }

    deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Called from `Recorder.onSamples` (audio thread).
    nonisolated var feed: @Sendable ([Float]) -> Void {
        { [sink] samples in sink.yield(samples) }
    }

    /// While true, incoming audio is dropped (e.g. app backgrounded — CoreML
    /// GPU work in background can kill the process).
    nonisolated func setSuspended(_ suspended: Bool) {
        sink.suspended = suspended
    }

    func start() {
        guard status == .idle || status == .unavailable else { return }
        status = .loading("Preparing live captions…")
        committed = ""
        partial = ""

        let stream = sink.makeStream()
        pumpTask = Task {
            let engine: LiveTranscriptionEngine
            do {
                engine = try await LiveTranscriptionEngine.load { [weak self] p, _ in
                    Task { @MainActor [weak self] in
                        guard let self, case .loading = self.status else { return }
                        self.status = .loading("Downloading caption model… \(Int(p * 100))%")
                    }
                }
                try engine.startSession()
            } catch {
                status = .unavailable
                return
            }
            status = .live

            // Engine work happens off the main actor; one pump task = serial pushes.
            await Self.pump(stream: stream, engine: engine) { [weak self] update in
                await MainActor.run { self?.apply(update) }
            }
        }
    }

    func stop() {
        sink.finish()
    }

    func reset() {
        pumpTask?.cancel()
        pumpTask = nil
        sink.finish()
        status = .idle
        committed = ""
        partial = ""
    }

    private func apply(_ update: LiveTranscriptionEngine.Update) {
        if let delta = update.committedDelta {
            committed += delta
        }
        partial = update.partial
    }

    private nonisolated static func pump(
        stream: AsyncStream<[Float]>,
        engine: LiveTranscriptionEngine,
        deliver: @Sendable (LiveTranscriptionEngine.Update) async -> Void
    ) async {
        for await chunk in stream {
            if Task.isCancelled { return }
            if let update = engine.push(chunk) {
                await deliver(update)
            }
        }
        if let final = engine.finish() {
            await deliver(final)
        }
    }
}

/// Lock-protected bridge from the audio render thread into an AsyncStream.
private final class SampleSink: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var _suspended = false

    var suspended: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _suspended }
        set { lock.lock(); _suspended = newValue; lock.unlock() }
    }

    func makeStream() -> AsyncStream<[Float]> {
        lock.lock(); defer { lock.unlock() }
        continuation?.finish()
        let (stream, cont) = AsyncStream.makeStream(of: [Float].self)
        continuation = cont
        return stream
    }

    func yield(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        guard !_suspended else { return }
        continuation?.yield(samples)
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        continuation?.finish()
        continuation = nil
    }
}
