#if DEBUG
import Foundation

/// Opens a screen directly for design QA: `-BountyDebugScreen offer` (or a tab / onboarding step name).
enum DebugLaunch {
    static var screen: String? {
        UserDefaults.standard.string(forKey: "BountyDebugScreen")
    }

    static var onboardingStep: OnboardingView.Step? {
        switch screen {
        case "welcome": .welcome
        case "profileImport": .profileImport
        case "building": .building
        case "availability": .availability
        default: nil
        }
    }

    @MainActor
    static func apply(to router: AppRouter) {
        let tabs: [String: AppTab] = ["home": .home, "jobs": .jobs, "post": .post, "twin": .twin, "earnings": .earnings]
        let routes: [String: AppRoute] = [
            "notifications": .notifications,
            "profile": .profile,
            "lockScreenOffer": .lockScreenOffer, "offer": .offer, "jobDetail": .jobDetail,
            "proofCapture": .proofCapture, "proofCheck": .proofCheck, "proofChecklist": .proofChecklist,
            "fundJob": .fundJob, "reviewProof": .reviewProof, "postedJob": .postedJob
        ]
        guard let screen else { return }
        if let tab = tabs[screen] {
            router.reset(to: tab)
        } else if let route = routes[screen] {
            router.debugShow(route)
        }
    }
}
#endif
