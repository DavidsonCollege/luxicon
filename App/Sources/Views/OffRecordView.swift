import SwiftUI
import LuxiconKit

/// Full-screen "off the record" state. Committed dark treatment (fixed colors,
/// ignores the system appearance) so the shift from the recording screen is
/// unmistakable, with 1-on-1 confidentiality imagery. Capture is already stopped
/// by the time this is shown; the only action is `onResume`.
struct OffRecordView: View {
    let personName: String
    let pausedAt: TimeInterval
    let onResume: () -> Void

    // Fixed palette — deliberately not semantic colors (see doc comment).
    private static let accent = Color(red: 0.435, green: 0.690, blue: 1.0)   // #6FB0FF
    private static let dim = Color(red: 0.239, green: 0.427, blue: 0.639)    // #3D6DA3
    private static let heading = Color(red: 0.863, green: 0.906, blue: 0.949)
    private static let subtext = Color(red: 0.498, green: 0.576, blue: 0.659)
    private static let gradientTop = Color(red: 0.063, green: 0.137, blue: 0.227) // #10233A
    private static let gradientBottom = Color(red: 0.024, green: 0.051, blue: 0.090) // #060D17
    private static let resumeFill = Color(red: 0.184, green: 0.435, blue: 0.816) // #2F6FD0

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Self.gradientTop, Self.gradientBottom],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Two figures with a lock between them.
                HStack(spacing: 10) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(Self.accent)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Self.dim)
                    Image(systemName: "person.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(Self.accent)
                }
                .accessibilityHidden(true)

                Text("OFF THE RECORD")
                    .font(.caption.weight(.semibold))
                    .tracking(2)
                    .foregroundStyle(Self.accent)
                    .padding(.top, 28)

                Text("This stays between you and \(personName).")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Self.heading)
                    .padding(.top, 8)
                    .padding(.horizontal, 32)

                Text("No audio is being recorded or saved.\nPaused at \(TranscriptExport.timestamp(pausedAt))")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Self.subtext)
                    .padding(.top, 14)

                Spacer()

                Button(action: onResume) {
                    Label("Resume recording", systemImage: "record.circle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(Self.resumeFill)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
        }
    }
}

#Preview {
    OffRecordView(personName: "Priya", pausedAt: 252, onResume: {})
}
