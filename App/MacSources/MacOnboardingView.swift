import SwiftUI
import AVFoundation
import LuxiconKit

/// First-run sheet over the main window: name, microphone, voice.
struct MacOnboardingView: View {
    static let seenKey = "macOnboardingSeen"

    /// Whether to show it at launch: first run. Never under DEBUG automation
    /// (`-route`, `-recordWith`, or a scratch `-storePath`): its sheet would
    /// block the run (an attached sheet holds up `terminate:`, so the ⌘Q
    /// prompt never comes). `-route onboarding` presents it once the window
    /// is sized.
    static var shouldShow: Bool {
        #if DEBUG
        if DebugLaunchOptions.isRouted || DebugLaunchOptions.has("-recordWith")
            || DebugLaunchOptions.has("-storePath") { return false }
        #endif
        return !UserDefaults.standard.bool(forKey: seenKey)
    }

    @Environment(Store.self) private var store
    @Environment(LibraryIndex.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var step = 1
    @State private var micStatus: String?

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 16) {
            Text("Step \(step) of 3").font(.caption).foregroundStyle(.secondary)
            switch step {
            case 1:
                Text("What's your name?").font(.title2.bold())
                Text("Luxicon labels your side of each 1-on-1 with this name.")
                    .foregroundStyle(.secondary)
                TextField("Name shown in transcripts", text: $store.myName)
                    .onSubmit { store.save() }
                nav(next: "Continue") { store.save(); step = 2 }
            case 2:
                Text("Microphone").font(.title2.bold())
                Text("Luxicon records 1-on-1s with this Mac's microphone. Audio stays on this Mac.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Allow Microphone Access") {
                        Task {
                            let granted = await AVAudioApplication.requestRecordPermission()
                            micStatus = granted ? "Microphone access is on." : "Microphone access is off. You can turn it on in System Settings."
                        }
                    }
                    if let micStatus { Text(micStatus).font(.footnote).foregroundStyle(.secondary) }
                }
                nav(next: "Continue") { step = 3 }
            default:
                Text("Your voice").font(.title2.bold())
                Text("With your voice enrolled, Luxicon labels you and the other person automatically.")
                    .foregroundStyle(.secondary)
                if let file = library.voicePrint, file.embedding.count == VoiceEnrollment.embeddingDimension {
                    Button("Use voice print from iPhone") {
                        store.myVoiceEmbedding = file.embedding
                        store.save()
                        finish()
                    }
                    .buttonStyle(.borderedProminent)
                }
                HStack {
                    Button("Enroll here") {
                        finish()
                        openSettings()
                    }
                    Button("Skip") { finish() }
                }
                HStack { Button("Back") { step = 2 }; Spacer() }
            }
        }
        .padding(24)
        .frame(width: 440)
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private func nav(next: String, action: @escaping () -> Void) -> some View {
        HStack {
            if step > 1 { Button("Back") { step -= 1 } }
            Spacer()
            Button(next, action: action).keyboardShortcut(.defaultAction)
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        dismiss()
    }
}
