import SwiftUI

struct RootTabView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    // Jobs funded through Stripe checkout (payments branch), shown under Jobs > Posted.
    @StateObject private var postedJobs = PostedJobsStore()
    // The job being posted, shared by Post a job → Proof checklist → Fund.
    @State private var postDraft = PostDraft()

    var body: some View {
        Group {
            if let route = router.route {
                routeView(route)
                    .id(route)
            } else {
                VStack(spacing: 0) {
                    ZStack {
                        tabView(router.tab)
                            .id(router.tab)
                            .transition(.opacity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    BountyTabBar(selection: router.tab) { router.select($0) }
                }
            }
        }
        .environment(\.screenExiting, router.transition.isExiting)
        .preferredColorScheme(router.route?.usesDarkStatusBar == true ? .dark : .light)
        .environmentObject(postedJobs)
        .environment(postDraft)
        // Re-check pending checkouts whenever the app comes back to the foreground.
        .task(id: scenePhase) {
            if scenePhase == .active { await postedJobs.refresh() }
        }
        .onAppear(perform: consumePendingPushRoute)
        .onReceive(NotificationCenter.default.publisher(for: .pushRouteChanged)) { _ in
            consumePendingPushRoute()
        }
    }

    @ViewBuilder
    private func tabView(_ tab: AppTab) -> some View {
        switch tab {
        case .home: HomeView()
        case .jobs: JobsView()
        case .post: CreateJobView()
        case .twin: TwinView()
        case .earnings: EarningsView()
        }
    }

    @ViewBuilder
    private func routeView(_ route: AppRoute) -> some View {
        switch route {
        case .lockScreenOffer: LockScreenOfferView()
        case .offer: OfferView()
        case .jobDetail: JobDetailView()
        case .proofCapture: ProofCaptureView()
        case .proofCheck: ProofCheckView()
        case .proofChecklist: ProofChecklistView()
        case .fundJob: FundJobView()
        case .reviewProof: ReviewProofView()
        }
    }

    private func consumePendingPushRoute() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: PushRoute.destinationKey) == "jobs" else { return }
        router.reset(to: .jobs)
        defaults.removeObject(forKey: PushRoute.destinationKey)
    }
}

/// Five tabs: Home, Jobs, Post, Twin, Earnings. Post is always the yellow action.
struct BountyTabBar: View {
    let selection: AppTab
    let onSelect: (AppTab) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            item(.home, title: "Home", icon: .house)
            item(.jobs, title: "Jobs", icon: .briefcase)
            item(.post, title: "Post", icon: .plus)
            item(.twin, title: "Twin", icon: .sparkles)
            item(.earnings, title: "Earnings", icon: .wallet)
        }
        .padding(.top, 5)
        .frame(height: 49, alignment: .top)
        .background {
            BountyColor.canvas
                .overlay(alignment: .top) {
                    BountyColor.divider.frame(height: 1)
                }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func item(_ tab: AppTab, title: String, icon: BountyIcon) -> some View {
        let isSelected = tab == selection
        let isPost = tab == .post
        return Button {
            onSelect(tab)
        } label: {
            VStack(spacing: 3) {
                IconGlyph(icon: icon, size: 24, weight: isPost ? .semibold : .regular)
                    .foregroundStyle(isSelected || isPost ? BountyColor.inkPrimary : BountyColor.inkTertiary)
                    .frame(width: isPost ? 52 : 56, height: 36)
                    .background {
                        Capsule()
                            .fill(isPost ? BountyColor.yellow : BountyColor.pill)
                            .opacity(isPost || isSelected ? 1 : 0)
                    }
                Text(title)
                    .bountyType(.caption)
                    .foregroundStyle(isSelected || isPost ? BountyColor.inkPrimary : BountyColor.inkTertiary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .animation(Motion.tabSwitch, value: isSelected)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    RootTabView()
        .environment(AppRouter())
}
