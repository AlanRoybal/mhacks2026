import LocalAuthentication
import MapKit
import SwiftUI

/// "Accept asks for Face ID." Falls back to accepting when the device has no biometrics set up.
@MainActor
enum AcceptGate {
    static func confirm() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Accept this job")
        } catch {
            return false
        }
    }
}

// MARK: - 08 Offer

struct OfferView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppServices.self) private var services
    @Environment(MarketplaceStore.self) private var marketplace
    /// Set when the offer ends before the worker gets it (US-26).
    @State private var outcome: OfferOutcome?
    /// Kept so the screen still shows the real offer after the store drops it (expired, taken).
    @State private var lastJob: PostedJob?
    @State private var lastOffer: MarketplaceOffer?

    private var job: PostedJob? { marketplace.offeredJob ?? lastJob }
    private var offer: MarketplaceOffer? { marketplace.currentOffer ?? lastOffer }
    /// Sample text only for previews and sample mode, never in front of a real offer.
    private var isSample: Bool { services.api == nil }

    enum OfferOutcome {
        case expired, taken, tooLate, failed(String)

        var title: String {
            switch self {
            case .expired: "This offer expired"
            case .taken: "Someone else got this one"
            case .tooLate: "Not enough time left"
            case .failed: "Couldn\u{2019}t accept"
            }
        }

        var detail: String {
            switch self {
            case .expired: "Offers last under a minute. Your twin keeps looking and will send the next good match."
            case .taken: "Another worker accepted first, or the job moved on. Your twin keeps looking."
            case .tooLate: "The deadline is too close to finish it now."
            case .failed(let message): message
            }
        }
    }

    var body: some View {
        BountyScreen(glow: ScreenGlow(BountyColor.glowCream, height: 520)) {
            NavRow(leadingIcon: .x, leadingLabel: "Close", leadingAction: router.back) {
                if outcome == nil, let expiry = offer?.expiresAt {
                    OfferCountdown(expiry: expiry) { remaining in
                        Chip(label: "Expires in \(remaining)", tone: .coral)
                    }
                } else if outcome == nil {
                    Chip(label: "New offer", tone: .coral)
                } else {
                    Chip(label: "Closed", tone: .grey)
                }
            } trailing: {
                EmptyView()
            }
            .entrance(.top)

            if let outcome {
                VStack(alignment: .leading, spacing: 6) {
                    Text(outcome.title).bountyType(.headline)
                    Text(outcome.detail).bountyType(.subhead)
                }
                .foregroundStyle(BountyColor.creamInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .tintedPanel(BountyColor.cream, radius: BountyRadius.row)
                .transition(.opacity)
            }
            VStack(spacing: 2) {
                Text("Your twin found you")
                    .bountyType(.subheadStrong)
                    .foregroundStyle(BountyColor.creamInk)
                Text(job?.payText ?? (isSample ? "$15" : ""))
                    .bountyType(.money(size: 88, lineHeight: 92))
                    .foregroundStyle(BountyColor.inkPrimary)
                if let offer {
                    Text("≈ \(offer.hourlyRate.formatted(.currency(code: job?.currency.rawValue ?? "USD")))/hr · about \(offer.estMinutes) min")
                        .bountyType(.bodyStrong)
                        .foregroundStyle(BountyColor.inkSecondary)
                } else if isSample {
                    Text("≈ $90.00/hr · about 10 min")
                        .bountyType(.bodyStrong)
                        .foregroundStyle(BountyColor.inkSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            .entrance(.top)

            Text(job?.title ?? (isSample ? "Sketch a coffee shop logo" : "Offer"))
                .bountyType(.title)
                .foregroundStyle(BountyColor.inkPrimary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .entrance(.top)

            if let photos = job?.posterPhotos, !photos.isEmpty {
                JobPhotoStrip(urls: photos)
                    .entrance(.rest(0))
            }

            if let location = job?.location {
            OfferMap(location: location)
                .frame(height: 130)
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 6) {
                        IconGlyph(icon: .navigation, size: 14)
                        Text(travelText)
                            .bountyType(.footnote)
                    }
                    .foregroundStyle(BountyColor.inkPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(BountyColor.canvas, in: Capsule())
                    .padding(12)
                }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .accessibilityElement(children: .combine)
                .entrance(.rest(0))
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    IconGlyph(icon: .sparkles, size: 18)
                    Text("Why your twin picked this")
                        .bountyType(.bodyStrong)
                }
                Text(offer?.matchReason ?? job?.matchReason ?? (isSample ? "You sent 3 logo invoices this year (Gmail) and list brand design on LinkedIn. You’re free until 7 PM." : "It matches your skills and preferences."))
                    .bountyType(.subhead)
            }
            .foregroundStyle(BountyColor.lavenderInk)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tintedPanel(BountyColor.lavenderSoft)
            .entrance(.rest(1))

            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(text: "Proof you’ll submit")
                FlowLayout(spacing: 8) {
                    if let checklist = job?.checklist, !checklist.isEmpty {
                        ForEach(checklist.prefix(4)) { item in
                            Chip(label: item.text, tone: .cream)
                        }
                    } else {
                        Chip(label: "Photos or a video of the finished work", tone: .cream)
                    }
                }
            }
            .entrance(.rest(2))

            // Before accepting: what Bounty will check, and what it records about the worker.
            if let plan = job?.verification {
                VerificationPlanCard(plan: plan, audience: .worker)
                    .entrance(.rest(3))
            }
        } bottom: {
            if outcome != nil {
                PillButton(title: "Back to home") { router.finish(on: .home) }
            } else {
                HStack(spacing: 12) {
                    PillButton(title: "Decline", style: .secondary) {
                        Task {
                            if services.api != nil { _ = await marketplace.respond(api: services.api, accept: false) }
                            router.offerDeclined = true
                            router.finish(on: .home)
                        }
                    }
                    PillButton(title: marketplace.isLoading ? "Accepting…" : "Accept", icon: .scanFace) {
                        Task { await accept() }
                    }
                    .disabled(marketplace.isLoading)
                }
            }
        }
        .onAppear {
            lastJob = marketplace.offeredJob
            lastOffer = marketplace.currentOffer
        }
    }

    /// "Remote", or "0.4 mi · 8 min travel · 1200 S University Ave".
    private var travelText: String {
        guard let job else { return isSample ? "0.4 mi · 8 min travel" : "" }
        if job.isRemote { return "Remote" }
        return [job.distanceText, offer?.travelMinutes.map { "\($0) min travel" }, job.location?.address.isEmpty == false ? job.location?.address : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func accept() async {
        guard await AcceptGate.confirm() else { return }
        guard services.api != nil else {
            router.open(.jobDetail)
            return
        }
        if let fresh = marketplace.offeredJob { lastJob = fresh }
        if let fresh = marketplace.currentOffer { lastOffer = fresh }
        // The store dropped the offer on its last refresh: the server already ended it.
        guard marketplace.currentOffer != nil else {
            withAnimation(Motion.press) { outcome = .expired }
            return
        }
        // The server's clock decides (US-26); a phone that's a few seconds off still asks.
        if let job = await marketplace.respond(api: services.api, accept: true) {
            router.open(.jobDetail, workerJob: job.id)
            return
        }
        withAnimation(Motion.press) {
            switch marketplace.lastErrorCode {
            case "offer_expired": outcome = .expired
            // After the countdown ends the server may already have moved the job on; that's still "expired".
            case "offer_not_current": outcome = (lastOffer?.expiresAt).map { $0 <= .now } == true ? .expired : .taken
            case "not_enough_time": outcome = .tooLate
            default: outcome = .failed(marketplace.errorMessage ?? "Please try again.")
            }
        }
    }
}

/// The job's spot on a map for in-person jobs; the illustrated map for remote ones (US-31).
private struct OfferMap: View {
    let location: JobLocation

    var body: some View {
        let center = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
        Map(initialPosition: .region(MKCoordinateRegion(center: center, latitudinalMeters: 1600, longitudinalMeters: 1600))) {
            Marker(location.address.isEmpty ? "Job" : location.address, coordinate: center)
            UserAnnotation()
        }
        .allowsHitTesting(false)
    }
}

/// Wraps children onto new lines, like the chip rows in the design.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = Self.size(of: subviews[index], maxWidth: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = Self.size(of: subviews[index], maxWidth: width)
            let proposedWidth = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if proposedWidth > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }

    /// The child's natural size, capped at the row width.
    private static func size(of subview: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let natural = subview.sizeThatFits(.unspecified)
        guard natural.width > maxWidth, maxWidth.isFinite else { return natural }
        return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }
}

#Preview("Offer") {
    OfferView()
        .environment(AppRouter())
        .environment(AppServices())
        .environment(MarketplaceStore())
}
