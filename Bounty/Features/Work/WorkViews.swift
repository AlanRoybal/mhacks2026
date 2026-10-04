import CoreLocation
import SwiftUI

// MARK: - 09 Job detail — in progress

struct JobDetailView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppServices.self) private var services
    @Environment(MarketplaceStore.self) private var marketplace
    @StateObject private var location = JobLocationProvider()
    @State private var actionError: String?
    @State private var history: [TimelineEntry] = []
    @State private var confirmsWithdraw = false

    private var job: PostedJob? {
        marketplace.workingJobs.first { $0.id == router.workerJobId }
            ?? marketplace.workingJobs.first
    }

    private var requirements: [String] { job?.checklist.map(\.text) ?? [] }

    var body: some View {
        BountyScreen {
            NavRow(leadingAction: router.back) {
                Chip(label: job?.status.displayName ?? "In progress", tone: .lavender)
            } trailing: {
                if job?.allows("withdraw") == true {
                    Menu {
                        Button("Withdraw from job", systemImage: "arrow.uturn.backward", role: .destructive) { confirmsWithdraw = true }
                    } label: {
                        IconGlyph(icon: .ellipsis, size: 20)
                            .foregroundStyle(BountyColor.inkPrimary)
                            .frame(width: 44, height: 44)
                            .background(BountyColor.pill, in: Circle())
                    }
                    .accessibilityLabel("More")
                }
            }
            .entrance(.top)

            HStack(spacing: 14) {
                StickerTile(sticker: job?.displayJob.sticker ?? .coffee, background: job?.displayJob.tileColor ?? BountyColor.cream, size: 64, stickerSize: 54, radius: 19)
                TitleSubtitle(title: job?.title ?? "Job", subtitle: job.map { "\($0.payText) · Due \($0.deadlineText)" } ?? "", titleType: .headline)
            }
            .entrance(.top)

            HStack(spacing: 12) {
                InitialsAvatar(initials: Self.initials(job?.poster?.name ?? "?"), background: BountyColor.creamBand, foreground: BountyColor.creamInk)
                TitleSubtitle(
                    title: job?.poster?.name ?? "Requester",
                    subtitle: [job?.poster?.rating.map { "★ \($0.formatted(.number.precision(.fractionLength(1))))" } ?? "New requester",
                               job?.isRemote == false ? job?.location?.address : "Remote"].compactMap { $0 }.joined(separator: " · ")
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .borderedCard(radius: BountyRadius.row)
            .entrance(.top)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("What counts as done")
                        .bountyType(.bodyStrong)
                        .foregroundStyle(BountyColor.inkPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Chip(label: "Locked", tone: .grey)
                }
                ForEach(requirements, id: \.self) { requirement in
                    HStack(spacing: 12) {
                        StatusBadge(status: .todo)
                        Text(requirement)
                            .bountyType(.subhead)
                            .foregroundStyle(BountyColor.inkPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 6)
                }
            }
            .padding(16)
            .borderedCard()
            .entrance(.rest(0))

            if let plan = job?.verification {
                VerificationPlanCard(plan: plan, audience: .worker)
                    .entrance(.rest(0))
            }

            if let job {
                JobThreadCard(jobId: job.id, role: .worker, counterpartName: job.poster?.name)
                    .entrance(.rest(1))
            }

            if !history.isEmpty {
                JobHistoryCard(entries: history, payment: job?.payment)
                    .entrance(.rest(1))
            }

            if let job, job.status == .released || job.status == .refunded {
                RatePosterCard(job: job)
                    .entrance(.rest(1))
            }

            if let code = job?.challengeCode {
                HStack {
                    Text("Proof code")
                    Spacer()
                    Text(code).monospaced().bold()
                }
                .padding(14)
                .tintedPanel(BountyColor.cream, radius: BountyRadius.row)
            }

            if let actionError {
                Text(actionError)
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.red)
            }

            HStack(spacing: 12) {
                StickerView(sticker: .shield, size: 40)
                Text("\(job?.payText ?? "$15") is held safely. It releases when your proof passes review.")
                    .bountyType(.subhead)
                    .foregroundStyle(BountyColor.mintInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .tintedPanel(BountyColor.mint, radius: BountyRadius.row)
            .entrance(.rest(2))
        } bottom: {
            PillButton(title: primaryTitle, icon: job?.status == .accepted ? .locate : .camera) {
                beginProof()
            }
            .disabled(marketplace.isLoading || job == nil)
        }
        .confirmationDialog("Withdraw from this job?", isPresented: $confirmsWithdraw, titleVisibility: .visible) {
            Button("Withdraw", role: .destructive) { Task { await withdraw() } }
        } message: {
            Text("It goes back to matching for someone else, and it lowers your reliability score.")
        }
        .task(id: job?.status) {
            guard let job, let api = services.api else { return }
            history = (try? await api.request(.get, "jobs/\(job.id)/timeline")) ?? []
        }
    }

    static func initials(_ name: String) -> String {
        name.split(separator: " ").compactMap { $0.first(where: \.isLetter) }.prefix(2).map(String.init).joined().uppercased()
    }

    /// Gives the job back before submitting. It re-opens for matching and lowers reliability.
    private func withdraw() async {
        guard let job, let api = services.api else { return }
        do {
            try await api.send(.post, "jobs/\(job.id)/withdraw")
            await marketplace.refresh(api: api)
            router.back()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private var primaryTitle: String {
        switch job?.status {
        case .accepted: "Check in & start"
        case .submitted, .inReview, .disputed, .released, .refunded: "See proof results"
        default: "Add proof"
        }
    }

    private func beginProof() {
        guard let job, services.api != nil else { return }
        switch job.status {
        case .accepted:
            break
        case .submitted, .inReview, .disputed, .released, .refunded:
            router.open(.proofCheck, workerJob: job.id)
            return
        default:
            router.open(.proofCapture, workerJob: job.id)
            return
        }
        Task {
            let coordinate: CLLocationCoordinate2D?
            if job.isRemote {
                coordinate = nil
            } else {
                coordinate = await location.current()?.coordinate
                guard coordinate != nil else {
                    actionError = "Location access is required to check in for this job."
                    return
                }
            }
            if await marketplace.start(
                api: services.api,
                jobId: job.id,
                latitude: coordinate?.latitude,
                longitude: coordinate?.longitude
            ) != nil {
                router.open(.proofCapture, workerJob: job.id)
            } else {
                actionError = marketplace.errorMessage
            }
        }
    }
}

/// The worker rates the requester once the job is paid or refunded (US-57).
private struct RatePosterCard: View {
    @Environment(AppServices.self) private var services
    @Environment(MarketplaceStore.self) private var marketplace
    let job: PostedJob
    @State private var stars = 0
    @State private var comment = ""
    @State private var isSending = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let given = job.ratings?.byWorker {
                Text("You rated \(job.poster?.name ?? "the requester")").bountyType(.bodyStrong)
                Text(String(repeating: "★", count: given.stars) + String(repeating: "☆", count: 5 - given.stars))
                    .font(.title3)
                    .foregroundStyle(BountyColor.yellowDeep)
                    .accessibilityLabel("\(given.stars) of 5 stars")
            } else {
                Text("How was working for \(job.poster?.name ?? "this requester")?").bountyType(.bodyStrong)
                HStack(spacing: 6) {
                    ForEach(1...5, id: \.self) { value in
                        Button { stars = value } label: {
                            Image(systemName: value <= stars ? "star.fill" : "star")
                                .font(.title2)
                                .foregroundStyle(BountyColor.yellowDeep)
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel("\(value) star\(value == 1 ? "" : "s")")
                    }
                }
                TextField("Anything to add? (optional)", text: $comment, axis: .vertical)
                    .lineLimit(1...3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .fieldBackground(height: nil)
                PillButton(title: isSending ? "Sending\u{2026}" : "Send rating", style: .secondary) { Task { await send() } }
                    .disabled(stars == 0 || isSending)
                if let message { Text(message).bountyType(.footnote).foregroundStyle(BountyColor.red) }
            }
        }
        .foregroundStyle(BountyColor.inkPrimary)
        .padding(16)
        .borderedCard()
    }

    private func send() async {
        guard let api = services.api else { return }
        isSending = true
        defer { isSending = false }
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let updated: PostedJob = try await api.request(.post, "jobs/\(job.id)/rating", body: RatingBody(stars: stars, comment: trimmed.isEmpty ? nil : trimmed))
            marketplace.replace(updated)
        } catch {
            message = error.localizedDescription
        }
    }

    private struct RatingBody: Encodable, Sendable {
        let stars: Int
        let comment: String?
    }
}

final class JobLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    @MainActor
    func current() async -> CLLocation? {
        await withCheckedContinuation { continuation in
            self.continuation?.resume(returning: nil)
            self.continuation = continuation
            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            default:
                continuation.resume(returning: nil)
                self.continuation = nil
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestLocation()
        } else if manager.authorizationStatus != .notDetermined {
            continuation?.resume(returning: nil)
            continuation = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        continuation?.resume(returning: locations.last)
        continuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        continuation?.resume(returning: nil)
        continuation = nil
    }
}

#Preview("Job detail") {
    JobDetailView()
        .environment(AppRouter())
        .environment(AppServices())
        .environment(MarketplaceStore())
}
