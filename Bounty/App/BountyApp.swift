import SwiftUI

@main
struct BountyApp: App {
    @UIApplicationDelegateAdaptor(PushNotificationManager.self) private var pushNotifications
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    /// Poster-side state. Swap `MockJobsAPI()` for the real client once Backend is live.
    @State private var posterStore = PosterStore(api: MockJobsAPI())

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    RootTabView()
                } else {
                    OnboardingView {
                        hasCompletedOnboarding = true
                    }
                }
            }
            .environment(posterStore)
            .task(id: hasCompletedOnboarding) {
                if hasCompletedOnboarding {
                    await pushNotifications.requestAuthorization()
                }
            }
        }
    }
}
