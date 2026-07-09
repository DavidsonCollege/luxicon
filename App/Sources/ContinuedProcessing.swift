import Foundation
#if os(iOS)
import BackgroundTasks
#endif

#if os(iOS)

/// Bridges a session's processing Task to an iOS 26 continuous background
/// task (`BGContinuedProcessingTask`), so MLX/GPU inference can keep running
/// after the app is backgrounded instead of being cancelled. The system shows
/// task progress in a Live Activity and may expire the task under resource
/// pressure or if the user cancels it there.
///
/// Constraints (BackgroundTasks framework rules):
/// - Task identifiers must match the wildcard entry in
///   `BGTaskSchedulerPermittedIdentifiers` (`<bundleID>.<context>.*`) and the
///   concrete identifier must be unique per submission — the system kills the
///   app on a second registration of the same identifier.
/// - Requesting `.gpu` requires the
///   `com.apple.developer.background-tasks.continued-processing.gpu`
///   entitlement and a device where `BGTaskScheduler.supportedResources`
///   contains `.gpu`. Diarization is GPU-bound, so on devices without
///   background GPU no task is submitted and the cancel-on-background
///   fallback in `handleScenePhaseChange` stays in effect.
@available(iOS 26.0, *)
@MainActor
final class ContinuedProcessing {
    static let shared = ContinuedProcessing()

    /// Prefix matching the `edu.davidson.luxicon.processing.*` wildcard
    /// declared in Info.plist.
    private static let identifierPrefix = "edu.davidson.luxicon.processing."
    private static let progressUnits: Int64 = 1000

    /// Sessions whose task launched with background GPU access; these must
    /// not be cancelled when the app is backgrounded.
    private(set) var backgroundCapable: Set<UUID> = []

    /// Runs on expiration (user cancelled the Live Activity, or the system
    /// reclaimed resources) to cancel the session's processing Task.
    private var expirationHandlers: [UUID: () -> Void] = [:]

    /// Identifiers submitted but not yet launched, so an early finish can
    /// withdraw the queued request.
    private var pendingIdentifiers: [UUID: String] = [:]

    private let live = LiveTasks()

    /// True when this device can run GPU work from a backgrounded app.
    var deviceSupportsBackgroundGPU: Bool {
        BGTaskScheduler.supportedResources.contains(.gpu)
    }

    /// Submit a continuous background task for a session whose processing
    /// Task just started. No-op on devices without background GPU support.
    func begin(sessionId: UUID, title: String, onExpiration: @escaping () -> Void) {
        guard deviceSupportsBackgroundGPU, backgroundCapable.contains(sessionId) == false else { return }
        let identifier = Self.identifierPrefix + UUID().uuidString

        // Continued-processing tasks are exempt from the register-at-launch
        // rule, so the launch handler is registered just before submission.
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier, using: nil
        ) { [live] task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            task.progress.totalUnitCount = Self.progressUnits
            task.expirationHandler = {
                // Complete promptly — the cancelled processing Task unwinds
                // asynchronously and must not hold the slot while it does.
                task.setTaskCompleted(success: false)
                Task { @MainActor in
                    ContinuedProcessing.shared.expire(sessionId: sessionId)
                }
            }
            live.store(task, for: sessionId)
            Task { @MainActor in
                ContinuedProcessing.shared.markLaunched(sessionId: sessionId)
            }
        }
        guard registered else { return }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: title,
            subtitle: "Preparing…"
        )
        request.requiredResources = .gpu
        // If the system can't run the task right now, fail the submission so
        // the session cleanly keeps the cancel-on-background behavior rather
        // than sitting in a queue with no background protection.
        request.strategy = .fail

        do {
            try BGTaskScheduler.shared.submit(request)
            expirationHandlers[sessionId] = onExpiration
            pendingIdentifiers[sessionId] = identifier
        } catch {
            // Refused (queue full, entitlement mismatch): fall back silently.
        }
    }

    /// Mirror pipeline progress into the task's Live Activity. Accurate
    /// progress matters: the system preferentially expires stalled tasks.
    func report(sessionId: UUID, fraction: Double, stage: String) {
        live.with(sessionId) { task in
            task.progress.completedUnitCount =
                Int64((fraction * Double(Self.progressUnits)).rounded())
            task.updateTitle(task.title, subtitle: stage)
        }
    }

    /// Complete the session's continuous task (processing finished, failed,
    /// or was cancelled). Safe to call when no task was ever granted.
    func end(sessionId: UUID, success: Bool) {
        backgroundCapable.remove(sessionId)
        expirationHandlers[sessionId] = nil
        if let task = live.take(sessionId) {
            if success {
                task.progress.completedUnitCount = Self.progressUnits
            }
            task.setTaskCompleted(success: success)
        } else if let identifier = pendingIdentifiers[sessionId] {
            // Submitted but never launched: withdraw the queued request.
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
        pendingIdentifiers[sessionId] = nil
    }

    private func markLaunched(sessionId: UUID) {
        // Only guard sessions that still have an active submission; a task
        // launching after end() already ran is completed by end()'s take().
        guard pendingIdentifiers[sessionId] != nil else { return }
        backgroundCapable.insert(sessionId)
    }

    private func expire(sessionId: UUID) {
        _ = live.take(sessionId)  // Already completed in the expiration handler.
        backgroundCapable.remove(sessionId)
        pendingIdentifiers[sessionId] = nil
        let handler = expirationHandlers.removeValue(forKey: sessionId)
        handler?()
    }
}

/// Lock-guarded storage for `BGContinuedProcessingTask` handles, which arrive
/// on the scheduler's background queue and are used from the main actor.
/// (`NSProgress` and task completion are thread-safe.)
@available(iOS 26.0, *)
private final class LiveTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: BGContinuedProcessingTask] = [:]

    func store(_ task: BGContinuedProcessingTask, for id: UUID) {
        lock.withLock { tasks[id] = task }
    }

    func take(_ id: UUID) -> BGContinuedProcessingTask? {
        lock.withLock { tasks.removeValue(forKey: id) }
    }

    func with(_ id: UUID, _ body: (BGContinuedProcessingTask) -> Void) {
        let task = lock.withLock { tasks[id] }
        if let task { body(task) }
    }
}

#endif
