import Foundation
import ActivityKit

/// Starts/ends the recording Live Activity alongside the Recorder lifecycle.
///
/// Only the activity's `id` (Sendable) is stored; the non-Sendable `Activity`
/// handle is re-resolved inside the task that ends it, which keeps Swift 6
/// region isolation happy.
@MainActor
final class RecordingActivityController {
    static let shared = RecordingActivityController()

    private var activityId: String?

    func start(personName: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()
        let attributes = RecordingActivityAttributes(personName: personName)
        let state = RecordingActivityAttributes.ContentState(startDate: Date())
        let activity = try? Activity.request(
            attributes: attributes,
            content: .init(state: state, staleDate: nil)
        )
        activityId = activity?.id
    }

    func end() {
        guard let id = activityId else { return }
        activityId = nil
        Task.detached {
            for activity in Activity<RecordingActivityAttributes>.activities where activity.id == id {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
