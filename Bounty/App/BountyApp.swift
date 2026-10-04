import SwiftUI
import StripePaymentSheet
@preconcurrency import CoinbaseWalletSDK

@main
struct BountyApp: App {
    @UIApplicationDelegateAdaptor(PushNotificationManager.self) private var pushNotifications
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var services: AppServices
    @State private var router = AppRouter()
    /// The poster's posted jobs: the backend when configured and running, sample data otherwise.
    @State private var posterStore: PosterStore
    /// The launch animation plays once per cold launch, then hands off to Home or Welcome.
    @State private var hasLaunched = false
    /// Startup work the launch animation waits on (up to its 2.5 s cap): restoring the saved session.
    @State private var isWarm = false

    init() {
        BountyWallet.configure()
        let services = AppServices()
        _services = State(initialValue: services)
        _posterStore = State(initialValue: PosterStore.live(session: services.session))
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if hasLaunched {
                    appContent
                        .transition(.opacity)
                } else {
                    LaunchView(isReady: $isWarm) {
                        // Home (or Welcome) mounts now, so it plays its normal page enter.
                        withAnimation(.easeOut(duration: 0.2)) { hasLaunched = true }
                    }
                    .transition(.opacity)
                }
            }
            .task {
                #if DEBUG
                // Debug screen shortcuts (`-BountyDebugScreen`) open straight to the screen.
                if DebugLaunch.screen != nil { hasLaunched = true }
                #endif
                _ = await services.session.isSignedIn
                isWarm = true
            }
            .environment(services)
            .environment(router)
            .environment(posterStore)
            // At the root, so a link that cold-launches the app isn't lost during the launch animation.
            .onOpenURL { url in
                if url.scheme == "bounty", url.host() == "wallet" {
                    NotificationCenter.default.post(name: .payoutSetupReturned, object: nil)
                    return
                }
                if StripeAPI.handleURLCallback(with: url) { return }
                _ = try? CoinbaseWalletSDK.shared.handleResponse(url)
            }
        }
    }

    @ViewBuilder
    private var appContent: some View {
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
        .task(id: hasCompletedOnboarding) {
            guard hasCompletedOnboarding else { return }
            #if DEBUG
            if !(await services.session.isSignedIn) { try? await services.signInForDemo() }
            if DebugLaunch.screen != nil { return }
            #endif
            await pushNotifications.requestAuthorization()
        }
    }
}
