import SwiftUI

/// The soft gradient at the top of most screens.
struct ScreenGlow {
    var colors: [Color]
    var height: CGFloat

    init(_ color: Color, height: CGFloat) {
        colors = [color, Color.white.opacity(0)]
        self.height = height
    }

    init(colors: [Color], height: CGFloat) {
        self.colors = colors
        self.height = height
    }
}

/// Lays out a screen the way every Figma frame does (20 pt gutters, content under the
/// status bar, bottom actions 12 pt above the home indicator) and plays the page
/// enter and exit choreography.
struct BountyScreen<Content: View, Bottom: View>: View {
    var background: Color = BountyColor.canvas
    var glow: ScreenGlow?
    var spacing: CGFloat = 16
    var scrolls = true
    /// Rubber-band even when the content fits. On for the main pages (tabs, Notifications); flows and forms only scroll when they overflow.
    var alwaysBounces = false
    @ViewBuilder let content: Content
    @ViewBuilder let bottom: Bottom

    @State private var phase = EntrancePhase.hidden

    var body: some View {
        Group {
            if scrolls {
                ScrollView {
                    stack
                }
                .scrollBounceBehavior(alwaysBounces ? .always : .basedOnSize)
                .scrollIndicators(.hidden)
            } else {
                stack
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Screens without a bottom button (most tabs) shouldn't reserve its padding under the content.
            if Bottom.self != EmptyView.self {
                bottom
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
                    .offset(y: phase.bottomOffset)
                    .opacity(phase == .settled ? 1 : 0)
                    .animation(bottomAnimation, value: phase)
            }
        }
        // The glow sits behind the content so a tall glow never changes the layout.
        .background(alignment: .top) {
            if let glow {
                LinearGradient(colors: glow.colors, startPoint: .top, endPoint: .bottom)
                    .frame(height: glow.height)
                    .frame(maxWidth: .infinity)
                    .opacity(phase.glowOpacity)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }
        }
        .background(background.ignoresSafeArea())
        .entranceDriver($phase)
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 16)
        .offset(y: phase.contentOffset)
    }

    private var bottomAnimation: Animation {
        switch phase {
        case .exiting: Motion.exit
        case .hidden, .top: Motion.enterTop
        case .settled: Motion.enterRest.delay(Motion.stagger * 2)
        }
    }
}

extension BountyScreen where Bottom == EmptyView {
    init(
        background: Color = BountyColor.canvas,
        glow: ScreenGlow? = nil,
        spacing: CGFloat = 16,
        scrolls: Bool = true,
        alwaysBounces: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.background = background
        self.glow = glow
        self.spacing = spacing
        self.scrolls = scrolls
        self.alwaysBounces = alwaysBounces
        self.content = content()
        self.bottom = EmptyView()
    }
}
