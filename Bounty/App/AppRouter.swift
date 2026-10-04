import Observation
import SwiftUI

enum AppTab: Hashable, CaseIterable {
    case home
    case jobs
    case post
    case twin
    case earnings
}

/// Full-screen destinations that sit above the tab bar.
enum AppRoute: Hashable {
    case notifications
    case offer
    case jobDetail
    case proofCapture
    case proofCheck
    case proofChecklist
    case fundJob
    case reviewProof
    /// A job the user posted, with its status timeline.
    case postedJob
}

@MainActor
@Observable
final class AppRouter {
    struct Location: Equatable {
        var tab: AppTab
        var route: AppRoute?
    }

    private(set) var location = Location(tab: .home, route: nil)
    private var history: [Location] = []
    let transition = ScreenTransition()

    /// When the current offer stops being available.
    let offerExpiry = Date.now.addingTimeInterval(42)
    var offerDeclined = false
    var jobsSegment = JobsSegment.working
    /// The posted job the poster screens (checklist, fund, posted job, review) are showing.
    var posterJobId: String?
    var workerJobId: String?

    var tab: AppTab { location.tab }
    var route: AppRoute? { location.route }

    /// Opens a full-screen route after the current screen exits.
    func open(_ route: AppRoute) {
        navigate(to: Location(tab: location.tab, route: route), push: true)
    }

    /// Opens a poster screen for one of the user's posted jobs.
    func open(_ route: AppRoute, posterJob jobId: String) {
        posterJobId = jobId
        open(route)
    }

    func open(_ route: AppRoute, workerJob jobId: String) {
        workerJobId = jobId
        open(route)
    }

    /// Returns to a tab's root after the current screen exits, ending the flow.
    func finish(on tab: AppTab) {
        navigate(to: Location(tab: tab, route: nil), push: false, clearHistory: true)
    }

    func back() {
        let previous = history.popLast() ?? Location(tab: location.tab, route: nil)
        navigate(to: previous, push: false)
    }

    /// Tab bar selection: a 150 ms crossfade into the destination's enter animation.
    func select(_ tab: AppTab) {
        guard tab != location.tab || location.route != nil, !transition.isExiting else { return }
        history.removeAll()
        withAnimation(Motion.tabSwitch) {
            location = Location(tab: tab, route: nil)
        }
    }

    /// Jumps straight to a tab without an exit, e.g. after onboarding or from a notification.
    func reset(to tab: AppTab) {
        history.removeAll()
        location = Location(tab: tab, route: nil)
    }

    #if DEBUG
    func debugShow(_ route: AppRoute) {
        location = Location(tab: location.tab, route: route)
    }
    #endif

    private func navigate(to destination: Location, push: Bool, clearHistory: Bool = false) {
        guard destination != location else { return }
        let current = location
        transition.perform { [weak self] in
            guard let self else { return }
            if clearHistory {
                history.removeAll()
            } else if push {
                history.append(current)
            }
            location = destination
        }
    }
}
