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
/// needs to show.
struct JobLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BountyLiveAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Palette.night)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        PhaseIcon(state: state, size: 22)
                        Text(state.headline)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Palette.tint(for: state))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    OnSiteClock(state: state, alignment: .trailing)
                        .font(.title3.weight(.semibold))
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        StageTracker(state: state)
                        Text(state.detail(role: context.attributes.role))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                PhaseIcon(state: state, size: 18)
            } compactTrailing: {
                OnSiteClock(state: state, alignment: .trailing)
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: 52)
            } minimal: {
                PhaseIcon(state: state, size: 18)
            }
            .keylineTint(Palette.tint(for: state))
            .widgetURL(URL(string: "bounty://job/\(context.attributes.jobId)?role=\(context.attributes.role)"))
        }
    }
}

private enum Palette {
    static let night = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let lavender = Color(red: 0.53, green: 0.52, blue: 1.0)
    static let green = Color(red: 0.47, green: 0.94, blue: 0.05)
    static let yellow = Color(red: 0.99, green: 0.71, blue: 0.09)
    static let coral = Color(red: 1.0, green: 0.35, blue: 0.12)
    static let track = Color.white.opacity(0.18)

    static func tint(for state: BountyLiveAttributes.ContentState) -> Color {
        switch state.phase {
        case "on_site": green
        case "away", "signal_lost": coral
        case "in_review", "submitted", "verifying": yellow
        case "paid": green
        default: lavender
        }
    }
}

private struct LockScreenView: View {
    let attributes: BountyLiveAttributes
    let state: BountyLiveAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(attributes.payText)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Palette.green)
            }

            if state.minOnSiteSeconds > 0, !state.isFinished {
                HStack(alignment: .center, spacing: 12) {
                    PhaseIcon(state: state, size: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            // A ticking timer takes the full width, so it's left-aligned in it.
                            OnSiteClock(state: state, alignment: .leading)
                                .font(.title2.weight(.bold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("of \(state.minOnSiteSeconds / 60) min on site")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        MinimumBar(state: state)
                    }
                }
            }

            StageTracker(state: state)

            Text(isStale ? "Waiting for the next location update" : state.detail(role: attributes.role))
                .font(.caption)
                .foregroundStyle(Palette.tint(for: state))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(16)
    }

    private var subtitle: String {
        let who = attributes.counterpart.map { attributes.role == "worker" ? "for \($0)" : "\($0) is on it" }
        let progress = state.itemsTotal > 0 ? "\(state.itemsDone)/\(state.itemsTotal) proof" : nil
        return [who, progress].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }
}

/// Total on-site time: ticks on its own while on site, holds still while away.
private struct OnSiteClock: View {
    let state: BountyLiveAttributes.ContentState
    let alignment: TextAlignment

    var body: some View {
        if state.isOnSite, let start = state.timerStart {
            Text(timerInterval: start...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .multilineTextAlignment(alignment)
                .foregroundStyle(Palette.green)
        } else {
            Text(BountyLiveAttributes.ContentState.clock(state.onSiteSeconds))
                .monospacedDigit()
                .foregroundStyle(state.isFinished ? .white : Palette.tint(for: state))
        }
    }
}

/// Progress toward the on-site time the proof needs. Fills on its own while on site.
private struct MinimumBar: View {
    let state: BountyLiveAttributes.ContentState

    var body: some View {
        if state.isOnSite, let start = state.timerStart, !state.metMinimum {
            ProgressView(timerInterval: start...start.addingTimeInterval(TimeInterval(state.minOnSiteSeconds)), countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.linear)
            .tint(Palette.green)
        } else {
            ProgressView(value: Double(min(state.onSiteSeconds, state.minOnSiteSeconds)), total: Double(max(state.minOnSiteSeconds, 1)))
                .progressViewStyle(.linear)
                .tint(state.metMinimum ? Palette.green : Palette.tint(for: state))
        }
    }
}

/// Started, on site, proof check, review, paid: the delivery-tracker row.
private struct StageTracker: View {
    let state: BountyLiveAttributes.ContentState

    private var stages: [String] {
        [state.minOnSiteSeconds > 0 ? "On site" : "Working", "Proof", "Review", state.phase == "refunded" ? "Refunded" : "Paid"]
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
        HStack(spacing: 4) {
            ForEach(Array(stages.enumerated()), id: \.offset) { index, label in
                VStack(alignment: .leading, spacing: 4) {
                    Capsule()
                        .fill(index <= current ? Palette.tint(for: state) : Palette.track)
                        .frame(height: 5)
                    Text(label)
                        .font(.caption2.weight(index == current ? .semibold : .regular))
                        .foregroundStyle(index <= current ? .white : .white.opacity(0.5))
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct PhaseIcon: View {
    let state: BountyLiveAttributes.ContentState
    let size: CGFloat

    private var symbol: String {
        switch state.phase {
        case "on_site": "mappin.and.ellipse"
        case "away": "figure.walk"
        case "signal_lost": "location.slash"
        case "submitted", "verifying": "sparkles"
        case "in_review": "person.crop.circle.badge.checkmark"
        case "paid": "checkmark.seal.fill"
        case "refunded", "closed": "xmark.circle"
        default: "hammer.fill"
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(Palette.tint(for: state))
            .frame(width: size, height: size)
            .background(Palette.tint(for: state).opacity(0.18), in: Circle())
    }
}
