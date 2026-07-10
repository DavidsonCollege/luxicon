import SwiftUI

/// Frames Luxicon as a free, open-source service of Davidson College and
/// invites a gift to the college. App Store Guideline 3.2.1 requires the
/// donation to happen outside the app, so the button opens Safari.
struct AboutGivingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Close")
            }
            .padding(.top, 16)

            // Scrolls at large Dynamic Type sizes; short content centers in
            // the space between the close row and the pinned button block.
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 0) {
                        Image(decorative: "AppIconLarge")
                            .resizable()
                            .frame(width: 116, height: 116)
                            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                            .shadow(color: Color("DavidsonRed").opacity(0.35), radius: 14, y: 8)

                        Text("Luxicon")
                            .font(.title2.bold())
                            .padding(.top, 16)
                        Text("A service of Davidson College")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color("DavidsonRed"))
                            .padding(.top, 2)

                        VStack(spacing: 12) {
                            Text("Luxicon is free and open source, built by Davidson College Technology & Innovation. Everything — recording, transcription, summaries — stays on your device.")
                            Text("If you like what you see, consider a gift to Davidson. Giving sustains the college's primary purpose: *developing humane instincts and disciplined and creative minds for lives of leadership and service.*")
                        }
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.top, 20)
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            Button {
                openURL(URL(string: "https://www.davidson.edu/giving")!)
            } label: {
                Text("Give to Davidson")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color("DavidsonRed"))
            .accessibilityHint("Opens davidson.edu/giving in Safari")

            Text("Opens davidson.edu/giving in Safari")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 8)

            Link("View the source on GitHub",
                 destination: URL(string: "https://github.com/DavidsonCollege/luxicon")!)
                .font(.footnote)
                .tint(Color("DavidsonRed"))
                .padding(.top, 14)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .presentationDragIndicator(.visible)
    }
}
