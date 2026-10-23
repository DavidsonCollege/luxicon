import SwiftUI
import LuxiconKit

/// Offers the voice print the iPhone pushed into ~/Luxicon. Never replaces an
/// enrolled voice without the user's say-so.
struct VoicePrintBanner: View {
    @Environment(Store.self) private var store
    @Environment(LibraryIndex.self) private var library

    static let dismissedKey = "voicePrintDismissedCreatedAt"
    @State private var dismissedAt: Double = UserDefaults.standard.double(forKey: VoicePrintBanner.dismissedKey)

    /// The offered print, or nil when there is nothing (new) to offer.
    private var offered: VoicePrintFile? {
        guard let file = library.voicePrint,
              file.embedding != store.myVoiceEmbedding,
              file.embedding.count == (store.myVoiceEmbedding?.count ?? VoiceEnrollment.embeddingDimension),
              file.createdAt.timeIntervalSince1970 != dismissedAt
        else { return nil }
        return file
    }

    var body: some View {
        if let file = offered {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Voice print from your iPhone, received \(file.createdAt.formatted(date: .abbreviated, time: .omitted)).",
                          systemImage: "iphone.and.arrow.forward")
                    HStack {
                        Button("Use It") { use(file) }
                            .buttonStyle(.borderedProminent)
                        Button("Not Now") { dismiss(file) }
                    }
                    Text("Enrolling here with this Mac's microphone can match your voice more reliably.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            #if DEBUG
            .task {
                if DebugLaunchOptions.has("-autoUseVoicePrint") { use(file) }
            }
            #endif
        }
    }

    private func use(_ file: VoicePrintFile) {
        store.myVoiceEmbedding = file.embedding
        store.save()
    }

    private func dismiss(_ file: VoicePrintFile) {
        let value = file.createdAt.timeIntervalSince1970
        UserDefaults.standard.set(value, forKey: Self.dismissedKey)
        dismissedAt = value
    }
}
