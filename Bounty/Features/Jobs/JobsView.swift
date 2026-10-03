import SwiftUI

enum JobsSegment: Hashable {
    case working, posted, done
}

// MARK: - 16 Jobs

struct JobsView: View {
    @Environment(AppRouter.self) private var router

    private func jobs(for segment: JobsSegment) -> [Job] {
        switch segment {
        case .working: SampleJobs.working
        case .posted: SampleJobs.posted
        case .done: SampleJobs.working.filter { $0.status == .paid }
        }
    }

    var body: some View {
        @Bindable var router = router
        BountyScreen {
            ScreenTitle(title: "Jobs") {
                IconButton(icon: .sliders, label: "Filters") {}
            }
            .entrance(.top)

            SegmentedPill(
                options: [(JobsSegment.working, "Working"), (.posted, "Posted"), (.done, "Done")],
                selection: $router.jobsSegment
            )
            .entrance(.top)

            VStack(spacing: 16) {
                ForEach(Array(jobs(for: router.jobsSegment).enumerated()), id: \.element.id) { index, job in
                    JobCard(job: job, isPosted: router.jobsSegment == .posted) { open(job) }
                        .entrance(index == 0 ? .top : .rest(index - 1))
                        .transition(.opacity.combined(with: .offset(y: 12)))
                }
            }
            .animation(Motion.enterRest, value: router.jobsSegment)
        }
    }

    private func open(_ job: Job) {
        if router.jobsSegment == .posted {
            router.open(.reviewProof)
            return
        }
        switch job.status {
        case .offered: router.open(.offer)
        case .accepted, .inProgress: router.open(.jobDetail)
        case .inReview, .paid: break
        }
    }
}

private struct JobCard: View {
    let job: Job
    let isPosted: Bool
    let action: () -> Void

    private var detail: String {
        isPosted ? "Jordan · submitted proof" : "\(job.location) · \(job.deadline)"
    }

    private var statusLabel: String {
        isPosted ? "Needs your review" : job.status.rawValue
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                StickerTile(sticker: job.sticker, background: job.tileColor, size: 56, stickerSize: 46, radius: 17)
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.title)
                        .bountyType(.bodyStrong)
                        .foregroundStyle(BountyColor.inkPrimary)
                    Text(detail)
                        .bountyType(.footnote)
                        .foregroundStyle(BountyColor.inkSecondary)
                    Chip(label: statusLabel, tone: isPosted ? .yellow : job.status.chipTone)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                Text("$\(job.pay)")
                    .bountyType(.moneyM)
                    .foregroundStyle(BountyColor.inkPrimary)
            }
            .padding(14)
            .borderedCard(radius: 22)
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - 15 Review proof

struct ReviewProofView: View {
    @Environment(AppRouter.self) private var router
    @State private var autoApproveAt = Date.now.addingTimeInterval(23 * 3600 + 41 * 60 + 10)

    private let checks = [
        ("Whole front lawn mowed", "4 photos · 96%"),
        ("Clippings bagged", "1 photo · 98%"),
        ("Sidewalk edges trimmed", "2 photos · 88%"),
        ("On site 2:02 – 2:51 PM", "GPS · verified")
    ]

    var body: some View {
        BountyScreen(spacing: 14) {
            NavRow(leadingAction: router.back) {
                Chip(label: "Needs your review", tone: .yellow)
            } trailing: {
                IconButton(icon: .ellipsis, label: "More") {}
            }
            .entrance(.top)

            Text("Review Jordan’s work")
                .bountyType(.title)
                .foregroundStyle(BountyColor.inkPrimary)
                .entrance(.top)

            HStack(spacing: 11) {
                proofPhoto("before-photo", label: "Before")
                proofPhoto("after-photo", label: "After")
            }
            .entrance(.top)

            HStack(spacing: 10) {
                IconGlyph(icon: .shieldCheck, size: 20)
                Text("AI check: 4 of 4 passed")
                    .bountyType(.bodyStrong)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("94% avg")
                    .bountyType(.subheadStrong)
            }
            .foregroundStyle(BountyColor.mintInk)
            .padding(14)
            .tintedPanel(BountyColor.mint, radius: BountyRadius.row)
            .entrance(.rest(0))

            VStack(spacing: 2) {
                ForEach(checks, id: \.0) { check in
                    HStack(spacing: 12) {
                        StatusBadge(status: .done)
                        Text(check.0)
                            .bountyType(.subheadStrong)
                            .foregroundStyle(BountyColor.inkPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(check.1)
                            .bountyType(.footnote)
                            .foregroundStyle(BountyColor.inkSecondary)
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .borderedCard()
            .entrance(.rest(1))

            HStack(spacing: 8) {
                IconGlyph(icon: .timer, size: 16)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Approves on its own in \(remaining(at: context.date)) if you don’t respond")
                        .bountyType(.footnote)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(BountyColor.inkSecondary)
            .entrance(.rest(2))
        } bottom: {
            VStack(spacing: 12) {
                PillButton(title: "Approve and pay $40", icon: .check) { router.finish(on: .earnings) }
                PillButton(title: "Dispute an item", icon: .flag, style: .secondary) {}
            }
        }
    }

    private func proofPhoto(_ asset: String, label: String) -> some View {
        Image(asset)
            .resizable()
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                Chip(label: label, tone: .dark).padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: BountyRadius.row, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(label) photo")
    }

    private func remaining(at date: Date) -> String {
        let seconds = max(0, Int(autoApproveAt.timeIntervalSince(date)))
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
    }
}

#Preview("Jobs") {
    JobsView()
        .environment(AppRouter())
}

#Preview("Review proof") {
    ReviewProofView()
        .environment(AppRouter())
}
