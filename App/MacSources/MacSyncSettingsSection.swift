import SwiftUI

/// The Mac's iPhone-sync settings: listener status and the pairing token.
struct MacSyncSettingsSection: View {
    @State private var status: ListenerStatus?
    @State private var token: String?
    @State private var copied = false

    var body: some View {
        Section {
            LabeledContent("Listener") {
                switch status {
                case .running: Label("Running", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .installedNotRunning: Label("Installed, not running", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                case .notInstalled: Label("Not installed", systemImage: "xmark.circle").foregroundStyle(.secondary)
                case nil: ProgressView().controlSize(.small)
                }
            }
            if let token {
                LabeledContent("Pairing token") {
                    HStack {
                        Text(token)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Button(copied ? "Copied" : "Copy") {
                            Pasteboard.copy(token)
                            copied = true
                        }
                    }
                }
            }
            if status == .notInstalled {
                Link("Download the listener installer",
                     destination: URL(string: "https://github.com/DavidsonCollege/luxicon/releases")!)
            }
        } header: {
            Text("iPhone sync")
        } footer: {
            Text("Pair your iPhone in Luxicon → My Voice → Mac sync with this token. Then use Send My Voice to Mac to bring your voice print over.")
        }
        .task {
            token = Self.readToken()
            status = await ListenerStatus.check()
        }
    }

    private static func readToken() -> String? {
        let url = LibraryLocation.url.appendingPathComponent(".sync-token")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
