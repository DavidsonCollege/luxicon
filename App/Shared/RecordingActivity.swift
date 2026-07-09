import Foundation
import ActivityKit
import AppIntents

// Compiled into both the app and the widget extension.

/// Live Activity shown while a 1-on-1 is being recorded (Dynamic Island +
/// lock screen). The timer renders from `startDate` on the system side, so
/// no updates are pushed during the recording.
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var startDate: Date
    }
    var personName: String
}

/// Control Center / Action button entry point. Runs in the widget extension,
/// which has no access to the app's data — so it opens the app via URL and
/// the app presents its person picker.
struct QuickRecordIntent: AppIntent {
    static let title: LocalizedStringResource = "Record 1-on-1"
    static let description = IntentDescription("Open Luxicon ready to record a 1-on-1.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(URL(string: "luxicon://quick-record")!))
    }
}
