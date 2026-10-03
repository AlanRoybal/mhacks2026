import SwiftUI
import StripePaymentSheet

@main
struct BountyApp: App {
    @UIApplicationDelegateAdaptor(PushNotificationManager.self) private var pushNotifications
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

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
            .task(id: hasCompletedOnboarding) {
                if hasCompletedOnboarding {
                    await pushNotifications.requestAuthorization()
                }
            }
            .onOpenURL { url in
                _ = StripeAPI.handleURLCallback(with: url)
            }
        }
    }
}
