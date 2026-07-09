import WidgetKit
import SwiftUI
import ActivityKit

@main
struct LuxiconWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
        QuickRecordControl()
    }
}

/// Dynamic Island + lock screen presentation while recording. The timer is
/// system-rendered from the activity's start date — zero updates needed.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            // Lock screen / banner
            HStack(spacing: 12) {
                Image(systemName: "record.circle")
                    .font(.title2)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording 1-on-1")
                        .font(.headline)
                    Text(context.attributes.personName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        // Redact who you're meeting with on the locked lock screen.
                        .privacySensitive()
                }
                Spacer()
                Text(timerInterval: timerRange(context), countsDown: false)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .frame(maxWidth: 70)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Recording", systemImage: "record.circle")
                        .foregroundStyle(.red)
                        .font(.callout.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: timerRange(context), countsDown: false)
                        .monospacedDigit()
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: 60)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("1-on-1 with \(context.attributes.personName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .privacySensitive()
                }
            } compactLeading: {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
            } compactTrailing: {
                Text(timerInterval: timerRange(context), countsDown: false)
                    .monospacedDigit()
                    .frame(maxWidth: 48)
            } minimal: {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
            }
        }
    }

    private func timerRange(
        _ context: ActivityViewContext<RecordingActivityAttributes>
    ) -> ClosedRange<Date> {
        // Open-ended timer: recording has no known end.
        context.state.startDate...Date(timeIntervalSinceNow: 24 * 60 * 60)
    }
}

/// Control Center button (assignable to the Action button on supported
/// devices): opens the app straight into the quick-record person picker.
struct QuickRecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "edu.davidson.luxicon.quickrecord") {
            ControlWidgetButton(action: QuickRecordIntent()) {
                Label("Record 1-on-1", systemImage: "record.circle")
            }
        }
        .displayName("Record 1-on-1")
        .description("Open Luxicon ready to record a 1-on-1.")
    }
}
