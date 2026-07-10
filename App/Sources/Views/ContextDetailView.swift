import SwiftUI

/// Full-screen view of one context blob (About You or a person's context),
/// pushed from a height-capped preview row. Editing happens only here — and
/// only while people sync is off; with sync on, the synced file owns the
/// text, so this screen is read-only and the footer says why.
struct ContextDetailView: View {
    let title: String
    @Binding var text: String
    /// Non-nil while people sync owns this text; shown as the read-only reason.
    let syncedExplanation: String?
    let editingExplanation: String
    let emptyPrompt: String
    let onSave: () -> Void

    var body: some View {
        Form {
            Section {
                if syncedExplanation != nil {
                    if text.isEmpty {
                        Text(emptyPrompt)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(text)
                            .textSelection(.enabled)
                    }
                } else {
                    TextField(emptyPrompt, text: $text, axis: .vertical)
                        .lineLimit(5...)
                }
            } footer: {
                Text(syncedExplanation ?? editingExplanation)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { onSave() }
    }
}

/// The tappable, height-capped preview that links to `ContextDetailView`.
struct ContextPreviewRow: View {
    let text: String
    let emptyPrompt: String

    var body: some View {
        if text.isEmpty {
            Text(emptyPrompt)
                .foregroundStyle(.secondary)
        } else {
            Text(text)
                .lineLimit(3)
        }
    }
}
