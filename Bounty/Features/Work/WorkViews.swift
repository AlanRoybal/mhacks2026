import CoreLocation
import MapKit
import SwiftUI

// MARK: - 09 Job detail — in progress

struct JobDetailView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppServices.self) private var services
    @Environment(MarketplaceStore.self) private var marketplace
    @StateObject private var location = JobLocationProvider()
    @State private var actionError: String?
    @State private var checkingLocation = false
    @State private var history: [TimelineEntry] = []
    @State private var confirmsWithdraw = false

    /// The job that was opened. Never a different one: if it's gone, the screen says so.
    private var job: PostedJob? {
        marketplace.workingJobs.first { $0.id == router.workerJobId }
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

            if let photos = job?.posterPhotos, !photos.isEmpty {
                JobPhotoStrip(urls: photos)
                    .entrance(.top)
            }

            if let job, !job.isRemote, let place = job.location {
                JobPlaceCard(place: place, startCheck: job.startCheck, started: job.status != .accepted)
                    .entrance(.top)
            }

            if let job, [.inProgress, .submitted, .inReview, .disputed].contains(job.status) {
                LiveSessionCard(job: job, role: .worker)
                    .entrance(.top)
            }

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

            if let actionError {
                Text(actionError)
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.red)
            }

            if let job {
                HStack(spacing: 12) {
                    StickerView(sticker: .shield, size: 40)
                    Text("\(job.payText) is held safely. It releases when your proof passes review.")
                        .bountyType(.subhead)
                        .foregroundStyle(BountyColor.mintInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                .tintedPanel(BountyColor.mint, radius: BountyRadius.row)
                .entrance(.rest(2))
            } else if !marketplace.isLoading {
                Text("This job isn\u{2019}t assigned to you anymore.")
                    .bountyType(.body)
                    .foregroundStyle(BountyColor.inkSecondary)
            }
        } bottom: {
            PillButton(title: primaryTitle, icon: job?.status == .accepted ? .locate : .camera) {
                beginProof()
            }
            .disabled(marketplace.isLoading || checkingLocation || job == nil)
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
        if checkingLocation { return "Checking your location\u{2026}" }
        return switch job?.status {
        case .accepted: "Check in & start"
        case .submitted, .inReview, .disputed, .released, .refunded: "See proof results"
        default: "Add proof"
        }
    }

    private func beginProof() {
        guard let job else { return }
        guard services.api != nil else {
            actionError = "You\u{2019}re signed out. Sign in again to start this job."
            return
        }
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
            var fix: CLLocation?
            if !job.isRemote {
                // Checked right now, at the job: a fresh fix, never a cached one.
                checkingLocation = true
                fix = await location.current(accuracy: 50, timeout: 15)
                checkingLocation = false
                guard fix != nil else {
                    actionError = location.failure == .denied
                        ? "Bounty needs your location to check you in. Turn on Location for Bounty in Settings."
                        : "Couldn\u{2019}t get your location. Step outside or near a window, then try again."
                    return
                }
            }
            if await marketplace.start(
                api: services.api,
                jobId: job.id,
                latitude: fix?.coordinate.latitude,
                longitude: fix?.coordinate.longitude,
                accuracyM: fix?.horizontalAccuracy
            ) != nil {
                router.open(.proofCapture, workerJob: job.id)
            } else {
                actionError = marketplace.errorMessage
            }
        }
    }
}

/// Where an in-person job happens: the address on a map, directions there, and, once started, how far
/// from it the worker checked in. Start is checked against this spot at the moment it's tapped.
private struct JobPlaceCard: View {
    let place: JobLocation
    let startCheck: StartCheck?
    let started: Bool

    private var coordinate: CLLocationCoordinate2D { .init(latitude: place.latitude, longitude: place.longitude) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 600, longitudinalMeters: 600))) {
                Marker(place.address.isEmpty ? "Job" : place.address, coordinate: coordinate)
                UserAnnotation()
            }
            .allowsHitTesting(false)
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: BountyRadius.row, style: .continuous))

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.address.isEmpty ? "Job location" : place.address)
                        .bountyType(.subheadStrong)
                        .foregroundStyle(BountyColor.inkPrimary)
                    Text(startCheck?.summary ?? (started ? "Started" : "You\u{2019}ll check in here when you tap Start."))
                        .bountyType(.footnote)
                        .foregroundStyle(startCheck == nil ? BountyColor.inkSecondary : BountyColor.mintInk)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
                    item.name = place.address.isEmpty ? "Bounty job" : place.address
                    item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault])
                } label: {
                    Label("Directions", icon: .navigation)
                        .bountyType(.footnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(BountyColor.pill, in: Capsule())
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(12)
        .borderedCard(radius: BountyRadius.row)
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
        guard let api = services.api else {
            message = "You\u{2019}re signed out. Sign in again to rate."
            return
        }
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

/// A fresh GPS fix at the moment it's needed (tapping Start, checking in, taking proof). Nothing is
/// tracked in the background: updates run only until a good enough fix arrives or the timeout passes.
@MainActor
final class JobLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum Failure {
        case denied, unavailable
    }

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    private var best: CLLocation?
    private var requestedAt = Date.distantPast
    private var wanted: CLLocationAccuracy = 50
    private var timeout: Task<Void, Never>?
    /// Why the last request came back empty.
    private(set) var failure: Failure?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// Waits for a fix taken after this call (never a cached one) that's accurate to `accuracy` meters.
    /// After `timeout` it settles for the best fresh fix so far, or nil if there was none.
    func current(accuracy: CLLocationAccuracy = 50, timeout seconds: TimeInterval = 12) async -> CLLocation? {
        finish(with: nil)
        failure = nil
        best = nil
        wanted = accuracy
        requestedAt = .now
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse:
                begin(timeout: seconds)
            default:
                failure = .denied
                finish(with: nil)
            }
        }
    }

    private func begin(timeout seconds: TimeInterval) {
        manager.startUpdatingLocation()
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            if self.best == nil { self.failure = .unavailable }
            self.finish(with: self.best)
        }
    }

    private func finish(with location: CLLocation?) {
        timeout?.cancel()
        timeout = nil
        manager.stopUpdatingLocation()
        continuation?.resume(returning: location)
        continuation = nil
    }

    private func received(_ locations: [CLLocation]) {
        guard continuation != nil else { return }
        // Only fixes taken after the request, with a real accuracy.
        for location in locations where location.timestamp >= requestedAt.addingTimeInterval(-1) && location.horizontalAccuracy >= 0 {
            if best == nil || location.horizontalAccuracy < best!.horizontalAccuracy { best = location }
        }
        if let best, best.horizontalAccuracy <= wanted { finish(with: best) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard self.continuation != nil else { return }
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                self.begin(timeout: 12)
            } else if status != .notDetermined {
                self.failure = .denied
                self.finish(with: nil)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.received(locations) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is temporary: keep waiting until the timeout.
        guard (error as? CLError)?.code != .locationUnknown else { return }
        Task { @MainActor in
            self.failure = (error as? CLError)?.code == .denied ? .denied : .unavailable
            self.finish(with: self.best)
        }
    }
}

#Preview("Job detail") {
    JobDetailView()
        .environment(AppRouter())
        .environment(AppServices())
        .environment(MarketplaceStore())
}
