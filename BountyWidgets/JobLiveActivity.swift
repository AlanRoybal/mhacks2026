import ActivityKit
import SwiftUI
import WidgetKit

@main
struct BountyWidgetsBundle: WidgetBundle {
    var body: some Widget {
        JobLiveActivity()
    }
}

/// A job in progress on the Lock Screen and in the Dynamic Island, like a delivery tracker: the stage the
/// job is at, the on-site clock (kept by SpacetimeDB, ticked here between updates) and the time the proof
/// needs to show. Styled after the app's Figma file (design/): the Lock Screen card follows the offer
/// notification (screen 07), the stages follow the job timeline's progress dots (screen 09).
struct JobLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BountyLiveAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Token.canvas)
                .activitySystemActionForegroundColor(Token.ink)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        PhaseIcon(state: state, size: 26, onDark: true)
                        Text(state.headline)
                            .font(Token.subheadStrong)
                            .foregroundStyle(Token.accent(for: state, onDark: true))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    OnSiteClock(state: state, alignment: .trailing, onDark: true)
                        .font(Token.moneyM)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(context.attributes.title)
                                .font(Token.bodyStrong)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(context.attributes.payText)
                                .font(Token.moneyM)
                        }
                        .foregroundStyle(.white)
                        ProgressDots(state: state, onDark: true)
                        Text(state.detail(role: context.attributes.role))
                            .font(Token.footnote)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                PhaseIcon(state: state, size: 22, onDark: true)
            } compactTrailing: {
                OnSiteClock(state: state, alignment: .trailing, onDark: true)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .frame(maxWidth: 54)
            } minimal: {
                PhaseIcon(state: state, size: 22, onDark: true)
            }
            .keylineTint(Token.accent(for: state, onDark: true))
            .widgetURL(URL(string: "bounty://job/\(context.attributes.jobId)?role=\(context.attributes.role)"))
        }
    }
}

/// The app's Figma tokens (design/tokens.json). The extension doesn't share the app's theme files.
private enum Token {
    static let ink = Color(hex: 0x000000)
    static let inkSecondary = Color(hex: 0x6B6B6B)
    static let inkTertiary = Color(hex: 0x9A9A9A)
    static let canvas = Color(hex: 0xFFFFFF)
    static let pill = Color(hex: 0xEEEEEE)
    static let divider = Color(hex: 0xEBEBEB)
    static let yellow = Color(hex: 0xFDB517)
    static let green = Color(hex: 0x78F00D)
    static let greenInk = Color(hex: 0x2F7A00)
    static let coral = Color(hex: 0xFF5A1F)
    static let lavender = Color(hex: 0x8784FF)
    static let lavenderSoft = Color(hex: 0xEEEAFE)
    static let lavenderInk = Color(hex: 0x2B2380)
    static let mint = Color(hex: 0xE3F8D2)
    static let mintInk = Color(hex: 0x1F5200)
    static let cream = Color(hex: 0xFDF4E3)
    static let creamInk = Color(hex: 0x4F3A08)

    // Typography: SF Pro per the handoff; money and the clock use the rounded Money styles.
    static let bodyStrong = Font.system(size: 17, weight: .semibold)
    static let subheadStrong = Font.system(size: 15, weight: .semibold)
    static let footnote = Font.system(size: 13, weight: .medium)
    static let caption = Font.system(size: 11, weight: .semibold)
    static let moneyM = Font.system(size: 22, weight: .heavy, design: .rounded)
    static let clock = Font.system(size: 26, weight: .heavy, design: .rounded)

    /// Color meaning from the design: green = verified/active, coral = urgent, yellow = action/review,
    /// lavender = matching and remote work.
    static func accent(for state: BountyLiveAttributes.ContentState, onDark: Bool) -> Color {
        switch state.phase {
        case "on_site", "paid": onDark ? green : greenInk
        case "away", "signal_lost": coral
        case "submitted", "verifying", "in_review": yellow
        case "refunded", "closed": onDark ? .white.opacity(0.6) : inkSecondary
        default: lavender
        }
    }

    /// The Chip tone for the phase (Chip: 28 pt capsule, Footnote).
    static func chip(for state: BountyLiveAttributes.ContentState) -> (fill: Color, ink: Color) {
        switch state.phase {
        case "on_site", "paid": (mint, mintInk)
        case "away", "signal_lost": (coral, .white)
        case "submitted", "verifying", "in_review": (cream, creamInk)
        case "refunded", "closed": (pill, inkSecondary)
        default: (lavenderSoft, lavenderInk)
        }
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// The Lock Screen card, in the style of the app's notification card (screen 07): the yellow Bounty tile,
/// the job and pay, then the clock with its Meter, the progress dots and a status chip. Lock Screen
/// activities are capped at 160 pt, so it stays to four rows.
private struct LockScreenView: View {
    let attributes: BountyLiveAttributes
    let state: BountyLiveAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Token.ink)
                    .frame(width: 28, height: 28)
                    .background(Token.yellow, in: RoundedRectangle(cornerRadius: 8.4, style: .continuous))
                Text(attributes.title)
                    .font(Token.bodyStrong)
                    .foregroundStyle(Token.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(attributes.payText)
                    .font(Token.moneyM)
                    .foregroundStyle(Token.ink)
            }

            if state.minOnSiteSeconds > 0, !state.isFinished {
                HStack(spacing: 10) {
                    // A ticking timer takes all the width it's given, so it gets a fixed slot.
                    OnSiteClock(state: state, alignment: .leading, onDark: false)
                        .font(Token.clock)
                        .minimumScaleFactor(0.7)
                        .frame(width: 78, alignment: .leading)
                    MinimumMeter(state: state)
                    Text("\(state.minOnSiteSeconds / 60) min")
                        .font(Token.footnote)
                        .foregroundStyle(Token.inkSecondary)
                }
            }

            ProgressDots(state: state, onDark: false)

            HStack(spacing: 8) {
                let chip = Token.chip(for: state)
                Text(state.headline)
                    .font(Token.footnote)
                    .foregroundStyle(chip.ink)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(chip.fill, in: Capsule())
                Text(isStale ? "Waiting for the next location update" : state.detail(role: attributes.role))
                    .font(Token.footnote)
                    .foregroundStyle(Token.inkSecondary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        // Solid, like the app's white notification card; the system would otherwise show it as glass.
        .background(Token.canvas)
    }
}

/// Total on-site time: ticks on its own while on site, holds still while away.
private struct OnSiteClock: View {
    let state: BountyLiveAttributes.ContentState
    let alignment: TextAlignment
    let onDark: Bool

    var body: some View {
        if state.isOnSite, let start = state.timerStart {
            Text(timerInterval: start...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .multilineTextAlignment(alignment)
                .foregroundStyle(onDark ? Token.green : Token.ink)
        } else {
            Text(BountyLiveAttributes.ContentState.clock(state.onSiteSeconds))
                .monospacedDigit()
                .foregroundStyle(state.isFinished ? (onDark ? .white : Token.ink) : Token.accent(for: state, onDark: onDark))
        }
    }
}

/// The design's Meter (8 pt capsule on surface/pill) toward the on-site time the proof needs. While on
/// site it fills on its own.
private struct MinimumMeter: View {
    let state: BountyLiveAttributes.ContentState

    var body: some View {
        if state.isOnSite, let start = state.timerStart, !state.metMinimum {
            ProgressView(timerInterval: start...start.addingTimeInterval(TimeInterval(state.minOnSiteSeconds)), countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(MeterStyle(fill: Token.green))
        } else {
            ProgressView(value: Double(min(state.onSiteSeconds, state.minOnSiteSeconds)), total: Double(max(state.minOnSiteSeconds, 1)))
                .progressViewStyle(MeterStyle(fill: state.metMinimum ? Token.green : Token.accent(for: state, onDark: false)))
        }
    }
}

private struct MeterStyle: ProgressViewStyle {
    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Token.pill)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(fill)
                        .frame(width: proxy.size.width * min(max(configuration.fractionCompleted ?? 0, 0), 1))
                }
        }
        .frame(height: 8)
    }
}

/// The job timeline's progress dots (screen 09): done is a green dot, the current step a yellow capsule,
/// upcoming steps grey dots, each over a caption.
private struct ProgressDots: View {
    let state: BountyLiveAttributes.ContentState
    let onDark: Bool

    private var stages: [String] {
        let proof = state.itemsTotal > 0 && current == 0 ? "Proof \(state.itemsDone)/\(state.itemsTotal)" : "Proof"
        return [state.minOnSiteSeconds > 0 ? "On site" : "Working", proof, "Review", state.phase == "refunded" ? "Refunded" : "Paid"]
    }

    private var current: Int {
        switch state.phase {
        case "submitted", "verifying": 1
        case "in_review": 2
        case "paid", "refunded", "closed": 3
        default: 0
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(Array(stages.enumerated()), id: \.offset) { index, label in
                let done = index < current || (index == current && state.isFinished)
                let active = index == current && !state.isFinished
                VStack(spacing: 5) {
                    Capsule()
                        .fill(done ? Token.green : active ? (state.phase == "away" || state.phase == "signal_lost" ? Token.coral : Token.yellow) : (onDark ? Color.white.opacity(0.2) : Token.divider))
                        .frame(width: active ? 36 : 12, height: 12)
                    Text(label)
                        .font(Token.caption)
                        .foregroundStyle(done || active ? (onDark ? .white : Token.ink) : (onDark ? .white.opacity(0.45) : Token.inkTertiary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct PhaseIcon: View {
    let state: BountyLiveAttributes.ContentState
    let size: CGFloat
    let onDark: Bool

    /// SF Symbols with the same meaning as the design's Lucide icons.
    private var symbol: String {
        switch state.phase {
        case "on_site": "mappin"
        case "away": "figure.walk"
        case "signal_lost": "location.slash"
        case "submitted", "verifying": "sparkles"
        case "in_review": "hourglass"
        case "paid": "checkmark.seal"
        case "refunded", "closed": "xmark"
        default: "timer"
        }
    }

    var body: some View {
        let accent = Token.accent(for: state, onDark: onDark)
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(accent)
            .frame(width: size, height: size)
            .background(accent.opacity(0.2), in: Circle())
    }
}
