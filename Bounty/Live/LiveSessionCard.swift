import SwiftUI

/// The job's live session, in the app: the on-site clock SpacetimeDB keeps, the time the proof needs,
/// where the worker is relative to the address, and what happened so far. The worker sees it on the job
/// and proof screens; the poster sees it on the posted job, with the option to follow on the Lock Screen.
/// Refreshes every 10 s while on screen; the clock ticks locally in between.
struct LiveSessionCard: View {
    enum Role: String {
        case worker, poster
    }

    @Environment(AppServices.self) private var services
    let job: PostedJob
    let role: Role
    var compact = false
    @State private var tracker = LiveTracker.shared
    @State private var onLockScreen = false
    @State private var unavailable = false

    private var session: LiveSessionView? { tracker.sessions[job.id] }

    var body: some View {
        Group {
            if let session {
                content(session)
            } else if unavailable {
                EmptyView()
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Connecting to the live session\u{2026}")
                        .bountyType(.footnote)
                        .foregroundStyle(BountyColor.inkSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .borderedCard()
            }
        }
        .task(id: job.id) {
            onLockScreen = tracker.hasActivity(jobId: job.id, role: role.rawValue)
            var first = true
            while !Task.isCancelled {
                let found = await tracker.refresh(jobId: job.id, api: services.api)
                unavailable = !found && session == nil
                if first, found, role == .worker { tracker.work(on: job, api: services.api) }
                first = false
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func content(_ session: LiveSessionView) -> some View {
        let state = session.content
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                LivePulse(active: state.isOnSite || session.phase == "started", color: tint(state))
                Text(state.headline)
                    .bountyType(.bodyStrong)
                    .foregroundStyle(BountyColor.inkPrimary)
                Spacer()
                Chip(label: session.provider == "spacetime" ? "Live \u{00B7} SpacetimeDB" : "Live", tone: .dark)
            }

            if !job.isRemote {
                clock(state)
            }

            Text(state.detail(role: role.rawValue))
                .bountyType(.subhead)
                .foregroundStyle(BountyColor.inkSecondary)

            if !compact {
                facts(session)
                if !session.events.isEmpty { timeline(session.events) }
            }

            if tracker.locationDenied, role == .worker, !job.isRemote {
                Label("Location is off, so time on site isn\u{2019}t counting. Turn on Location for Bounty in Settings.", icon: .alert)
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.red)
            }

            if role == .poster, !state.isFinished, tracker.activitiesEnabled {
                PillButton(title: onLockScreen ? "Following on your Lock Screen" : "Follow on Lock Screen", icon: onLockScreen ? .check : .lock, style: .secondary) {
                    Task {
                        if onLockScreen { await tracker.unfollow(jobId: job.id) } else { await tracker.follow(job, api: services.api) }
                        onLockScreen = tracker.hasActivity(jobId: job.id, role: role.rawValue)
                    }
                }
            }
        }
        .padding(16)
        .borderedCard()
    }

    /// The on-site clock and the time the proof needs, ticking every second.
    private func clock(_ state: BountyLiveAttributes.ContentState) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = state.timerStart.map { max(0, Int(context.date.timeIntervalSince($0))) } ?? state.onSiteSeconds
            let needed = state.minOnSiteSeconds
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(BountyLiveAttributes.ContentState.clock(seconds))
                        .bountyType(.money(size: 40, lineHeight: 44))
                        .monospacedDigit()
                        .foregroundStyle(BountyColor.inkPrimary)
                        .contentTransition(.numericText())
                    Text(needed > 0 ? "of \(needed / 60) min on site" : "on site")
                        .bountyType(.footnote)
                        .foregroundStyle(BountyColor.inkSecondary)
                }
                if needed > 0 {
                    ProgressView(value: Double(min(seconds, needed)), total: Double(needed))
                        .tint(seconds >= needed ? BountyColor.greenInk : tint(state))
                    Text(seconds >= needed
                         ? "Enough time on site for the proof."
                         : "\(Int(ceil(Double(needed - seconds) / 60))) more min on site before the proof can be approved automatically.")
                        .bountyType(.footnote)
                        .foregroundStyle(seconds >= needed ? BountyColor.mintInk : BountyColor.inkTertiary)
                }
            }
        }
    }

    private func facts(_ session: LiveSessionView) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let distance = session.lastDistanceM, let at = session.lastPingAt {
                factRow(.mapPin, "\(distance) m from the address \u{00B7} \(at.formatted(.relative(presentation: .named)))")
            }
            if session.itemsTotal > 0 {
                factRow(.camera, "\(session.itemsDone) of \(session.itemsTotal) proof items captured")
            }
            if session.leftSiteCount > 0 {
                factRow(.navigation, "Left the site \(session.leftSiteCount) time\(session.leftSiteCount == 1 ? "" : "s")")
            }
            if session.signalLostCount > 0 {
                factRow(.alert, "Location stopped \(session.signalLostCount) time\(session.signalLostCount == 1 ? "" : "s")")
            }
        }
    }

    private func factRow(_ icon: BountyIcon, _ text: String) -> some View {
        Label(text, icon: icon)
            .bountyType(.footnote)
            .foregroundStyle(BountyColor.inkSecondary)
    }

    private func timeline(_ events: [LiveSessionView.Event]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            ForEach(events.prefix(5)) { event in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(event.at.formatted(date: .omitted, time: .shortened))
                        .bountyType(.caption)
                        .foregroundStyle(BountyColor.inkTertiary)
                        .frame(width: 64, alignment: .leading)
                    Text(event.detail)
                        .bountyType(.footnote)
                        .foregroundStyle(BountyColor.inkPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func tint(_ state: BountyLiveAttributes.ContentState) -> Color {
        switch state.phase {
        case "on_site", "paid": BountyColor.greenInk
        case "away", "signal_lost": BountyColor.coral
        case "submitted", "verifying", "in_review": BountyColor.yellowDeep
        default: BountyColor.lavender
        }
    }
}

/// A dot that pulses while the session is live.
private struct LivePulse: View {
    let active: Bool
    let color: Color
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay {
                Circle()
                    .stroke(color.opacity(0.5), lineWidth: 2)
                    .scaleEffect(pulsing ? 2.2 : 1)
                    .opacity(pulsing ? 0 : 1)
            }
            .onAppear {
                guard active else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulsing = true }
            }
    }
}
