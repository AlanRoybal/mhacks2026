import SwiftUI
import StripePaymentSheet

@main
struct BountyApp: App {
    @UIApplicationDelegateAdaptor(PushNotificationManager.self) private var pushNotifications
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var services = AppServices()
    @State private var router = AppRouter()
    /// The poster's posted jobs: the backend when configured and running, sample data otherwise.
    @State private var posterStore = PosterStore.live()

    var body: some Scene {
        WindowGroup {
            Group {
                if hasCompletedOnboarding {
                    RootTabView()
                    #if DEBUG
                        .onAppear { DebugLaunch.apply(to: router) }
                    #endif
                } else {
                    OnboardingView {
                        // Onboarding ends on 04 Twin review.
                        router.reset(to: .twin)
                        hasCompletedOnboarding = true
                    }
                }
            }
            .environment(services)
            .environment(router)
            .environment(posterStore)
            .task(id: hasCompletedOnboarding) {
                guard hasCompletedOnboarding else { return }
                #if DEBUG
                if DebugLaunch.screen != nil { return }
                #endif
                await pushNotifications.requestAuthorization()
            }
            .onOpenURL { url in
                _ = StripeAPI.handleURLCallback(with: url)
            }
        }
    }
}
