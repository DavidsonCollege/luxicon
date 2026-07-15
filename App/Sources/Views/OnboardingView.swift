import SwiftUI

/// Seven-screen welcome tour: shown full-screen on first launch and replayable
/// from the roster's ⋯ menu. Swipeable paging with per-page entrance
/// animations that replay each time a page becomes current.
///
/// Sets `UserDefaults` "hasSeenOnboarding" on dismissal (skip, the final
/// button, or any other path) — deliberately not in `store.json`; it is UI
/// state, not library data.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pageID: Int?

    static let seenKey = "hasSeenOnboarding"
    private static let pageCount = 7

    /// Debug screenshot automation can open a specific page directly.
    private let initialPage: Int

    init(initialPage: Int = 0) {
        self.initialPage = min(max(initialPage, 0), Self.pageCount - 1)
        _pageID = State(initialValue: self.initialPage)
    }

    private var page: Int { pageID ?? 0 }

    var body: some View {
        ZStack {
            OnboardingPalette.ground.ignoresSafeArea()

            // A paging ScrollView rather than TabView(.page): pages inside a
            // paging TabView stay inset from the safe area no matter where
            // ignoresSafeArea is applied, and the hero must run full-bleed.
            // Content pages use fixed padding instead of safe-area insets.
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    Group {
                        HeroPage(active: page == 0).id(0)
                        WhatPage(active: page == 1).id(1)
                        FeaturesPage(active: page == 2).id(2)
                        WhyPage(active: page == 3).id(3)
                        HubPage(active: page == 4).id(4)
                        LoopPage(active: page == 5).id(5)
                        FinishPage(active: page == 6, onFinish: finish).id(6)
                    }
                    .containerRelativeFrame([.horizontal, .vertical])
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $pageID)
            .scrollIndicators(.hidden)
            .ignoresSafeArea()
            .task {
                // scrollPosition's initial value doesn't scroll a lazy paging
                // stack on first layout (which also resets the binding to 0);
                // jump through the binding once layout has settled.
                guard initialPage > 0 else { return }
                try? await Task.sleep(for: .milliseconds(150))
                var noAnimation = Transaction()
                noAnimation.disablesAnimations = true
                withTransaction(noAnimation) { pageID = initialPage }
            }

            chrome
        }
        .onDisappear {
            UserDefaults.standard.set(true, forKey: Self.seenKey)
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        dismiss()
    }

    /// Dots + skip overlay, shared across pages. The hero page gets white
    /// chrome over the dark scrim; content pages get ink-on-cream.
    private var chrome: some View {
        VStack {
            HStack {
                Spacer()
                if page < Self.pageCount - 1 {
                    Button("Skip") { finish() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(page == 0 ? Color.white.opacity(0.85) : .secondary)
                        .padding(.trailing, 20)
                        .padding(.top, 8)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                ForEach(0..<Self.pageCount, id: \.self) { i in
                    Button {
                        withAnimation { pageID = i }
                    } label: {
                        Circle()
                            .fill(dotColor(i))
                            .frame(width: 7, height: 7)
                            .frame(width: 16, height: 24) // comfortable tap target
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Page \(i + 1) of \(Self.pageCount)")
                }
            }
            .padding(.bottom, 6)
        }
    }

    private func dotColor(_ i: Int) -> Color {
        if page == 0 {
            return i == page ? .white : .white.opacity(0.35)
        }
        return i == page ? Color("DavidsonRed") : Color.primary.opacity(0.18)
    }
}

// MARK: - Palette

/// Warm grounds pulled from the wildcat artwork; Davidson red stays the only
/// accent. Fixed red is used where white text sits on it in both themes.
private enum OnboardingPalette {
    static let ground = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.110, green: 0.098, blue: 0.090, alpha: 1)   // warm near-black
            : UIColor(red: 0.965, green: 0.937, blue: 0.902, alpha: 1)   // warm cream
    })
    static let card = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.157, green: 0.141, blue: 0.129, alpha: 1)
            : UIColor(red: 1.0, green: 0.992, blue: 0.976, alpha: 1)     // warm paper
    })
    /// Davidson red as a fill — fixed, not the lighter dark-mode text variant.
    static let redFill = Color(red: 0.675, green: 0.102, blue: 0.184)    // #AC1A2F
    /// The asset color: adapts for legibility as text/icon on the ground.
    static let red = Color("DavidsonRed")
}

// MARK: - Entrance animation

/// Rise-and-fade entrance staggered by `delay`, replaying whenever the page
/// becomes current. With Reduce Motion, elements are simply visible.
private struct RiseIn: ViewModifier {
    let shown: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.7).delay(delay), value: shown)
    }
}

private extension View {
    func riseIn(_ shown: Bool, delay: Double) -> some View {
        modifier(RiseIn(shown: shown, delay: delay))
    }
}

/// Drives `shown` from the page-selection state so entrances replay on every
/// visit (TabView keeps neighbor pages alive, so `onAppear` fires too early).
private struct PageActivation: ViewModifier {
    let active: Bool
    @Binding var shown: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: active, initial: true) { _, isActive in
                if isActive {
                    shown = true
                } else {
                    var noAnimation = Transaction()
                    noAnimation.disablesAnimations = true
                    withTransaction(noAnimation) { shown = false }
                }
            }
    }
}

// MARK: - Page 1: hero

private struct HeroPage: View {
    let active: Bool
    @State private var shown = false
    @State private var glowing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Image(geo.size.width > geo.size.height
                      ? "OnboardingHeroLandscape" : "OnboardingHeroPortrait")
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                LinearGradient(
                    stops: [
                        .init(color: Color(red: 0.06, green: 0.05, blue: 0.04).opacity(0.9), location: 0),
                        .init(color: Color(red: 0.06, green: 0.05, blue: 0.04).opacity(0.45), location: 0.3),
                        .init(color: .clear, location: 0.55),
                    ],
                    startPoint: .bottom, endPoint: .top
                )
                .frame(height: geo.size.height * 0.7)

                VStack(spacing: 10) {
                    wordmark
                    Text("Bring your 1-on-1s into the light.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .riseIn(shown, delay: 0.9)
                    Text("SWIPE TO CONTINUE")
                        .font(.caption2.weight(.semibold))
                        .tracking(2)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.top, 26)
                        .riseIn(shown, delay: 1.6)
                }
                .padding(.bottom, 64)
            }
        }
        .modifier(PageActivation(active: active, shown: $shown))
        .task(id: shown) {
            // The "lux" light-up: a warm glow sweeps in after the letters
            // resolve, then settles to a steady glimmer.
            glowing = false
            guard shown, !reduceMotion else {
                glowing = shown
                return
            }
            try? await Task.sleep(for: .seconds(1.3))
            withAnimation(.easeInOut(duration: 1.8)) { glowing = true }
        }
    }

    /// "Luxicon", each letter resolving from blur into focus; the first three
    /// letters — Lux — light up.
    private var wordmark: some View {
        HStack(spacing: 0) {
            ForEach(Array("Luxicon".enumerated()), id: \.offset) { i, letter in
                Text(String(letter))
                    .font(.system(size: 46, weight: .heavy))
                    .foregroundStyle(.white)
                    .shadow(
                        color: Color(red: 1.0, green: 0.85, blue: 0.55)
                            .opacity(glowing && i < 3 ? 0.9 : 0),
                        radius: 14
                    )
                    .opacity(shown || reduceMotion ? 1 : 0)
                    .blur(radius: shown || reduceMotion ? 0 : 12)
                    .animation(
                        reduceMotion ? nil
                            : .easeOut(duration: 1.0).delay(0.1 + Double(i) * 0.08),
                        value: shown
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Luxicon")
    }
}

// MARK: - Page 2: what is Luxicon

private struct WhatPage: View {
    let active: Bool
    @State private var shown = false

    var body: some View {
        OnboardingContentPage {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "sun.max")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(OnboardingPalette.red)
                    .riseIn(shown, delay: 0.15)
                    .padding(.bottom, 24)
                Text("Be fully present in every 1-on-1.")
                    .font(.system(size: 32, weight: .heavy))
                    .riseIn(shown, delay: 0.3)
                (Text("Luxicon listens").foregroundStyle(OnboardingPalette.red)
                 + Text(" so you don't have to take notes."))
                    .font(.system(size: 32, weight: .heavy))
                    .padding(.top, 12)
                    .riseIn(shown, delay: 0.55)
                Text("It records, transcribes, and summarizes your meetings — entirely on your iPhone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 20)
                    .riseIn(shown, delay: 0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(PageActivation(active: active, shown: $shown))
    }
}

// MARK: - Page 3: key features

private struct FeaturesPage: View {
    let active: Bool
    @State private var shown = false

    var body: some View {
        OnboardingContentPage {
            VStack(alignment: .leading, spacing: 18) {
                Text("Everything a 1-on-1 needs.")
                    .font(.system(size: 26, weight: .heavy))
                    .riseIn(shown, delay: 0.15)
                    .padding(.bottom, 4)
                FeatureRow(symbol: "waveform.badge.mic",
                           title: "One-tap recording",
                           detail: "Set the phone on the table and talk.")
                    .riseIn(shown, delay: 0.35)
                FeatureRow(symbol: "person.2.wave.2",
                           title: "Knows who's speaking",
                           detail: "Speaker-labeled transcripts, matched to your people.")
                    .riseIn(shown, delay: 0.55)
                FeatureRow(symbol: "lock",
                           title: "Go off the record",
                           detail: "One tap pauses capture for sensitive moments — nothing is recorded until you resume.")
                    .riseIn(shown, delay: 0.75)
                FeatureRow(symbol: "sparkles",
                           title: "AI summaries",
                           detail: "Key points and action items via Apple Intelligence.")
                    .riseIn(shown, delay: 0.95)
                FeatureRow(symbol: "macbook.and.iphone",
                           title: "Syncs to your Mac",
                           detail: "Finished sessions land in a folder your tools can read.")
                    .riseIn(shown, delay: 1.15)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(PageActivation(active: active, shown: $shown))
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(OnboardingPalette.red)
                .frame(width: 46, height: 46)
                .background(OnboardingPalette.red.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.bold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Page 4: why Luxicon

private struct WhyPage: View {
    let active: Bool
    @State private var shown = false

    var body: some View {
        OnboardingContentPage {
            VStack(alignment: .leading, spacing: 12) {
                Text("Why Luxicon?")
                    .font(.system(size: 28, weight: .heavy))
                    .riseIn(shown, delay: 0.15)
                    .padding(.bottom, 6)
                WhyCard(symbol: "lock.shield",
                        title: "Private by design",
                        detail: "Audio, transcripts, and summaries never leave your device unless you send them.")
                    .riseIn(shown, delay: 0.35)
                WhyCard(symbol: "apple.logo",
                        title: "At home in the Apple ecosystem",
                        detail: "Siri, Shortcuts, widgets, the Action button, and LAN-only Mac sync.")
                    .riseIn(shown, delay: 0.6)
                WhyCard(symbol: "sparkles",
                        title: "AI-forward performance management",
                        detail: "Close the loop between your 1-on-1s and the AI tools that run the rest of your workflow.",
                        starred: true)
                    .riseIn(shown, delay: 0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(PageActivation(active: active, shown: $shown))
    }
}

private struct WhyCard: View {
    let symbol: String
    let title: String
    let detail: String
    var starred = false

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(starred ? .white : OnboardingPalette.red)
                .frame(width: 40, height: 40)
                .background(
                    starred ? Color.white.opacity(0.16) : OnboardingPalette.red.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                if starred {
                    Text("THE BIG ONE")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.18), in: Capsule())
                        .padding(.bottom, 3)
                }
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(starred ? .white : .primary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(starred ? .white.opacity(0.85) : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            starred ? OnboardingPalette.redFill : OnboardingPalette.card,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Page 5: AI-forward performance management

private struct HubPage: View {
    let active: Bool
    @State private var shown = false

    var body: some View {
        OnboardingContentPage {
            VStack(alignment: .leading, spacing: 0) {
                OrbitDiagram(active: active)
                    .frame(maxWidth: .infinity)
                    .riseIn(shown, delay: 0.15)
                    .padding(.bottom, 22)
                Text("AI-forward performance management")
                    .font(.system(size: 24, weight: .heavy))
                    .riseIn(shown, delay: 0.35)
                Text("Claude or ChatGPT already connects to where performance happens — your email, chat, meetings, and collaboration apps. Maybe even your HR system.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 14)
                    .riseIn(shown, delay: 0.6)
                Text("So you use it to prepare for 1-on-1s and critical conversations.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
                    .riseIn(shown, delay: 0.85)
                (Text("But how do you ") + Text("close the loop?").foregroundStyle(OnboardingPalette.red))
                    .font(.system(size: 19, weight: .heavy))
                    .padding(.top, 16)
                    .riseIn(shown, delay: 1.1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(PageActivation(active: active, shown: $shown))
    }
}

/// "Your LLM" hub with mail / chat / meetings / HR satellites in slow orbit.
/// Satellites counter-rotate so their glyphs stay upright.
private struct OrbitDiagram: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let satellites = ["envelope", "message", "video", "chart.bar"]
    private static let period: Double = 26

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let angle = reduceMotion ? Angle.zero
                : .degrees(t.truncatingRemainder(dividingBy: Self.period) / Self.period * 360)

            ZStack {
                ForEach(Array(Self.satellites.enumerated()), id: \.offset) { i, symbol in
                    let placement = angle + .degrees(Double(i) * 90)
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 40)
                        .background(OnboardingPalette.card, in: Circle())
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
                        .rotationEffect(-placement)  // keep the glyph upright
                        .offset(y: -88)
                        .rotationEffect(placement)
                }
                Circle()
                    .fill(OnboardingPalette.redFill)
                    .frame(width: 76, height: 76)
                    .background {
                        Circle().fill(OnboardingPalette.redFill.opacity(0.07)).frame(width: 116, height: 116)
                        Circle().fill(OnboardingPalette.redFill.opacity(0.05)).frame(width: 148, height: 148)
                    }
                Text("Your\nLLM")
                    .font(.system(size: 13, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
            }
            .frame(width: 216, height: 216)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Diagram: your LLM connected to email, chat, meetings, and HR apps")
    }
}

// MARK: - Page 6: closing the loop

private struct LoopPage: View {
    let active: Bool
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        OnboardingContentPage {
            VStack(alignment: .leading, spacing: 0) {
                loopDiagram
                    .frame(maxWidth: .infinity)
                    .riseIn(shown, delay: 0.15)
                    .padding(.bottom, 20)
                Text("That's where Luxicon comes in.")
                    .font(.system(size: 24, weight: .heavy))
                    .riseIn(shown, delay: 0.35)
                HStack(spacing: 4) {
                    ForEach(["RECORD", "TRANSCRIBE", "SUMMARIZE", "SYNC BACK"], id: \.self) { step in
                        Text(step)
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.3)
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(OnboardingPalette.red)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(OnboardingPalette.red.opacity(0.09), in: Capsule())
                    }
                }
                .padding(.top, 12)
                .riseIn(shown, delay: 0.55)
                Text("Luxicon transcribes your 1-on-1s, identifies speakers, and summarizes the conversation — then shares or automatically syncs the result back to Claude, ChatGPT, or wherever your performance tools live.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 16)
                    .riseIn(shown, delay: 0.75)
                Text("Transcripts are the record of what was actually discussed — so the documentation your LLM prepared in advance updates itself afterward.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
                    .riseIn(shown, delay: 1.0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(PageActivation(active: active, shown: $shown))
    }

    /// Loop-of-arrows motif rotating slowly around a steady mic.
    private var loopDiagram: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !active || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let angle = reduceMotion ? Angle.zero
                : .degrees(t.truncatingRemainder(dividingBy: 14) / 14 * 360)
            ZStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 104, weight: .thin))
                    .foregroundStyle(OnboardingPalette.red)
                    .rotationEffect(angle)
                Image(systemName: "mic")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(OnboardingPalette.red)
            }
            .frame(width: 150, height: 130)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Diagram: recording flows around a loop, back to your tools")
    }
}

// MARK: - Page 7: send-off

private struct FinishPage: View {
    let active: Bool
    let onFinish: () -> Void
    @State private var shown = false
    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        OnboardingContentPage {
            VStack(spacing: 0) {
                Image(decorative: "AppIconLarge")
                    .resizable()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: OnboardingPalette.redFill.opacity(0.35), radius: 16, y: 8)
                    .riseIn(shown, delay: 0.15)
                    .padding(.bottom, 24)
                Text("Closing the loop on AI-forward performance management.")
                    .font(.system(size: 25, weight: .heavy))
                    .multilineTextAlignment(.center)
                    .riseIn(shown, delay: 0.35)
                Text("That's Luxicon — a free, open-source service of Davidson College.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)
                    .riseIn(shown, delay: 0.6)
                Text("Built to help managers everywhere reclaim their time and practice better servant leadership, with a little AI magic.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                    .riseIn(shown, delay: 0.8)
                Button(action: onFinish) {
                    Text("Let's get started")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 36)
                        .padding(.vertical, 15)
                        .background(OnboardingPalette.redFill, in: Capsule())
                        .shadow(color: OnboardingPalette.redFill.opacity(0.35), radius: 12, y: 6)
                }
                .scaleEffect(breathing ? 1.035 : 1)
                .padding(.top, 28)
                .riseIn(shown, delay: 1.05)
            }
            .frame(maxWidth: .infinity)
        }
        .modifier(PageActivation(active: active, shown: $shown))
        .task(id: active) {
            breathing = false
            guard active, !reduceMotion else { return }
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }
}

// MARK: - Shared page scaffold

/// Content-page scaffold: scrolls at large Dynamic Type / small screens,
/// centers otherwise (the AboutGivingView pattern), constrained for iPad.
private struct OnboardingContentPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                content
                    .frame(maxWidth: 440)
                    .padding(.horizontal, 30)
                    .padding(.top, 72)
                    .padding(.bottom, 72)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

#Preview {
    OnboardingView()
}
