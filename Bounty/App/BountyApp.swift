import SwiftUI
import StripePaymentSheet
@preconcurrency import CoinbaseWalletSDK

@main
struct BountyApp: App {
    init() { BountyWallet.configure() }
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
                if StripeAPI.handleURLCallback(with: url) { return }
                _ = try? CoinbaseWalletSDK.shared.handleResponse(url)
            }
        }
    }
}
