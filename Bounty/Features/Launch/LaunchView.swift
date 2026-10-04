import SwiftUI

/// Cold-launch animation (Figma "05 Brand — logo & launch", Launch 0–4 and the launch motion spec).
///
///   0.00–0.45  bowls snap in from ±80 pt, mark 0.8 → 1.12, glow fades in at 0.6 → 0.9
///   0.45–0.80  mark settles to 1.0, sparkle spins in, wordmark then tagline rise 16 pt
///   0.80–1.20  hold: the sparkle twinkles; repeats while `isReady` is false, up to 2.5 s in all
///   1.20–1.40  exit: content lifts 24 pt and fades, glow grows to 1.6 and fades
///
/// Reduce Motion: no offsets, scale or rotation. The lockup fades in over 0.2 s, holds 0.4 s, then the
/// app crossfades in. It starts on white, the same as the static launch screen (`LaunchBackground`).
struct LaunchView: View {
    /// True once the app's startup work is done; the hold ends early when it is. A binding, so the
    /// running timeline sees it change.
    @Binding var isReady: Bool
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Layer state at time 0 (Launch 0 · static splash).
    @State private var topBowlOffset: CGFloat = -80
    @State private var bottomBowlOffset: CGFloat = 80
    @State private var bowlsOpacity = 0.0
    @State private var markScale: CGFloat = 0.8
    @State private var sparkleScale: CGFloat = 0
    @State private var sparkleRotation = -90.0
    @State private var wordmarkOffset: CGFloat = 16
    @State private var wordmarkOpacity = 0.0
    @State private var taglineOffset: CGFloat = 16
    @State private var taglineOpacity = 0.0
    @State private var glowScale: CGFloat = 0.6
    @State private var glowOpacity = 0.0
    @State private var exitLift: CGFloat = 0
    @State private var contentOpacity = 1.0

    /// Settled sizes from Launch 2–3.
    private static let markSize: CGFloat = 132
    private static let glowSize: CGFloat = 360
    /// The mark's center sits 42% of the way down the screen (y 360 of 852).
    private static let markCenterFraction: CGFloat = 360 / 852
    /// Hold ends by here so the whole launch, exit included, stays within 2.5 s.
    private static let holdDeadline: Duration = .milliseconds(2300)

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                mark
                BountyWordmark(size: 44)
                    .padding(.top, 20)
                    .offset(y: wordmarkOffset)
                    .opacity(wordmarkOpacity)
                Text("Your twin finds the work.")
                    .bountyType(.subhead)
                    .foregroundStyle(BountyColor.inkSecondary)
                    .padding(.top, 8)
                    .offset(y: taglineOffset)
                    .opacity(taglineOpacity)
            }
            .offset(y: exitLift)
            .opacity(contentOpacity)
            .frame(maxWidth: .infinity)
            .padding(.top, proxy.size.height * Self.markCenterFraction - Self.markSize / 2)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(BountyColor.canvas)
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bounty. Your twin finds the work.")
        .task { await run() }
    }

    private var mark: some View {
        ZStack {
            Circle()
                .fill(BountyColor.lavenderSoft)
                .frame(width: Self.glowSize, height: Self.glowSize)
                .scaleEffect(glowScale)
                .opacity(glowOpacity)
                // The glow belongs to the background; it doesn't lift with the content on exit.
                .offset(y: -exitLift)
            // The layers get their own mark-sized box: the larger glow would otherwise widen the ZStack
            // they're positioned in.
            ZStack {
                ZStack {
                    BountyMarkLayerView(layer: .topBowl, size: Self.markSize)
                        .offset(y: topBowlOffset)
                    // Drawn over the top bowl, as in the master.
                    BountyMarkLayerView(layer: .bottomBowl, size: Self.markSize)
                        .offset(y: bottomBowlOffset)
                }
                .opacity(bowlsOpacity)
                sparkle
            }
            .frame(width: Self.markSize, height: Self.markSize)
            .scaleEffect(markScale)
        }
        .frame(width: Self.markSize, height: Self.markSize)
    }

    /// The sparkle scales and spins around its own center, not the mark's.
    private var sparkle: some View {
        let frame = BountyMarkLayer.sparkle.frame
        let scale = Self.markSize / BountyMarkLayer.masterSize
        return Image(BountyMarkLayer.sparkle.assetName)
            .resizable()
            .renderingMode(.template)
            .foregroundStyle(BountyColor.inkPrimary)
            .frame(width: frame.width * scale, height: frame.height * scale)
            .rotationEffect(.degrees(sparkleRotation))
            .scaleEffect(sparkleScale)
            .position(x: frame.midX * scale, y: frame.midY * scale)
    }

    // MARK: Timeline

    private func run() async {
        if reduceMotion {
            await runReduced()
            return
        }
        let clock = ContinuousClock()
        let start = clock.now

        // 0.00–0.45 · Bowls snap in.
        withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
            topBowlOffset = 0
            bottomBowlOffset = 0
            bowlsOpacity = 1
            markScale = 1.12
            glowOpacity = 1
            glowScale = 0.9
        }
        try? await Task.sleep(for: .milliseconds(450))

        // 0.45–0.80 · Sparkle + wordmark.
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            markScale = 1
            glowScale = 1
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.6).delay(0.05)) {
            sparkleScale = 1
            sparkleRotation = 0
        }
        withAnimation(.easeOut(duration: 0.3)) {
            wordmarkOffset = 0
            wordmarkOpacity = 1
        }
        withAnimation(.easeOut(duration: 0.3).delay(0.1)) {
            taglineOffset = 0
            taglineOpacity = 1
        }
        try? await Task.sleep(for: .milliseconds(350))

        // 0.80–1.20 · Hold: the sparkle twinkles, and keeps twinkling while startup work finishes.
        repeat {
            withAnimation(.easeInOut(duration: 0.4)) { sparkleRotation += 90 }
            try? await Task.sleep(for: .milliseconds(400))
        } while !isReady && clock.now - start < Self.holdDeadline

        // 1.20–1.40 · Exit, matching the standard page exit.
        withAnimation(.easeIn(duration: 0.2)) {
            exitLift = -24
            contentOpacity = 0
            glowScale = 1.6
            glowOpacity = 0
        }
        try? await Task.sleep(for: .milliseconds(200))
        onFinished()
    }

    /// Reduce Motion: everything already in place; only opacity changes.
    private func runReduced() async {
        let clock = ContinuousClock()
        let start = clock.now
        topBowlOffset = 0
        bottomBowlOffset = 0
        markScale = 1
        sparkleScale = 1
        sparkleRotation = 0
        wordmarkOffset = 0
        taglineOffset = 0
        glowScale = 1
        withAnimation(.easeOut(duration: 0.2)) {
            bowlsOpacity = 1
            wordmarkOpacity = 1
            taglineOpacity = 1
            glowOpacity = 1
        }
        try? await Task.sleep(for: .milliseconds(600))
        while !isReady && clock.now - start < Self.holdDeadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        onFinished()
    }
}

#Preview("Launch") {
    LaunchView(isReady: .constant(true)) {}
}
