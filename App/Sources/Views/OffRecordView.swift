import SwiftUI
import LuxiconKit

/// Full-screen "off the record" state. Committed dark treatment (fixed colors,
/// ignores the system appearance) so the shift from the recording screen is
/// unmistakable, with 1-on-1 confidentiality imagery. Capture is already stopped
/// by the time this is shown; the only action is `onResume`.
///
/// `isMuted` (Mac only; the iPhone never sets it): off the record because the
/// microphone is muted. The copy says so, and Resume is disabled — unmuting
/// resumes the recording. `onUnmute`, when the app-level (system) mute is
/// on, adds an Unmute button that clears it in-app; a device's own hardware
/// mute can only be undone on the device.
struct OffRecordView: View {
    let personName: String
    let pausedAt: TimeInterval
    var isMuted = false
    var onUnmute: (() -> Void)?
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
                    Image(systemName: isMuted ? "mic.slash.fill" : "lock.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Self.dim)
                    Image(systemName: "person.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(Self.accent)
                }
                .accessibilityHidden(true)

                if isMuted {
                    Text("MICROPHONE MUTED — OFF THE RECORD")
                        .font(.caption.weight(.semibold))
                        .tracking(2)
                        .foregroundStyle(Self.accent)
                        .padding(.top, 28)
                        .accessibilityLabel("Microphone muted. Off the record.")
                } else {
                    Text("OFF THE RECORD")
                        .font(.caption.weight(.semibold))
                        .tracking(2)
                        .foregroundStyle(Self.accent)
                        .padding(.top, 28)
                }

                Text("This stays between you and \(personName).")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Self.heading)
                    .padding(.top, 8)
                    .padding(.horizontal, 32)

                if isMuted {
                    Text("No audio is being recorded or saved.\nUnmute to resume recording. Paused at \(TranscriptExport.timestamp(pausedAt))")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Self.subtext)
                        .padding(.top, 14)
                        .padding(.horizontal, 32)
                } else {
                    Text("No audio is being recorded or saved.\nPaused at \(TranscriptExport.timestamp(pausedAt))")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Self.subtext)
                        .padding(.top, 14)
                }

                Spacer()

                if isMuted, let onUnmute {
                    // App-level mute: unmute here, and recording resumes.
                    // Resume itself stays disabled (it would record silence).
                    VStack(spacing: 10) {
                        Button(action: onUnmute) {
                            Label("Unmute Microphone", systemImage: "mic")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Self.resumeFill)
                        .accessibilityHint("Recording resumes once the microphone is unmuted.")
                        Button(action: onResume) {
                            Label("Resume recording", systemImage: "record.circle")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(WaitingForUnmuteButtonStyle())
                        .disabled(true)
                        .accessibilityHint("Unmute your microphone to resume.")
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
                } else if isMuted {
                    // Resuming a muted mic would only record silence. A
                    // disabled prominent button all but vanishes on this
                    // background, so it's drawn as a readable outline.
                    Button(action: onResume) {
                        Label("Unmute your microphone to resume", systemImage: "mic.slash")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(WaitingForUnmuteButtonStyle())
                    .disabled(true)
                    .accessibilityHint("Recording resumes when you unmute.")
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
                } else {
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
}

extension OffRecordView {
    /// The muted overlay's disabled Resume: an outline with legible text.
    private struct WaitingForUnmuteButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(OffRecordView.heading.opacity(0.8))
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(OffRecordView.dim, lineWidth: 1))
        }
    }
}

#Preview {
    OffRecordView(personName: "Priya", pausedAt: 252, onResume: {})
}

#Preview("Muted (device)") {
    OffRecordView(personName: "Priya", pausedAt: 252, isMuted: true, onResume: {})
}

#Preview("Muted (system)") {
    OffRecordView(personName: "Priya", pausedAt: 252, isMuted: true, onUnmute: {}, onResume: {})
}
