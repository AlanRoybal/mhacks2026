import UIKit
import TwinKit
@preconcurrency import UserNotifications

enum PushNotificationDefinition {
    static let offerCategoryIdentifier = "BOUNTY_JOB_OFFER"
    static let acceptActionIdentifier = "BOUNTY_OFFER_ACCEPT"
    static let declineActionIdentifier = "BOUNTY_OFFER_DECLINE"
}

final class PushNotificationManager: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private let notificationCenter = UNUserNotificationCenter.current()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        notificationCenter.delegate = self
        registerCategories()
        return true
    }

    @MainActor
    func requestAuthorization() async {
        do {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .badge, .sound])
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
        } catch {
            NotificationCenter.default.post(name: .pushRegistrationFailed, object: error.localizedDescription)
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: PushRegistration.deviceTokenKey)
        NotificationCenter.default.post(name: .didRegisterPushToken, object: token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .pushRegistrationFailed, object: error.localizedDescription)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let jobID = userInfo["jobId"] as? String
        let offerID = userInfo["offerId"] as? String
        let type = userInfo["type"] as? String

        switch response.actionIdentifier {
        case PushNotificationDefinition.acceptActionIdentifier:
            if let offerID { _ = await respond(to: offerID, decision: .accept) }
            await routeToJobs(jobID: jobID, action: "accept")
        case PushNotificationDefinition.declineActionIdentifier:
            if let offerID { _ = await respond(to: offerID, decision: .decline) }
            await MainActor.run {
                NotificationCenter.default.post(name: .offerDeclined, object: jobID)
            }
        case UNNotificationDefaultActionIdentifier:
            // Poster alerts open the posted job itself; RootTabView decides between review and timeline.
            if let type, let jobID, PosterPush.posterTypes.contains(type) || PosterPush.sharedTypes.contains(type) {
                await routeToPostedJob(jobID: jobID, type: type)
            } else {
                await routeToJobs(jobID: jobID, action: "open")
            }
        default:
            break
        }
    }

    private func registerCategories() {
        let accept = UNNotificationAction(
            identifier: PushNotificationDefinition.acceptActionIdentifier,
            title: "Accept",
            options: [.authenticationRequired, .foreground]
        )
        let decline = UNNotificationAction(
            identifier: PushNotificationDefinition.declineActionIdentifier,
            title: "Decline",
            options: []
        )
        let offerCategory = UNNotificationCategory(
            identifier: PushNotificationDefinition.offerCategoryIdentifier,
            actions: [accept, decline],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        notificationCenter.setNotificationCategories([offerCategory])
    }

    private func respond(to offerID: String, decision: OfferDecision) async -> Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "BountyAPIBaseURL") as? String,
              let baseURL = URL(string: value), baseURL.host != nil else { return false }
        do {
            let api = APIClient(baseURL: baseURL, tokenProvider: SessionStore())
            _ = try await OfferService(api: api).respond(to: offerID, decision: decision)
            return true
        } catch {
            await MainActor.run {
                NotificationCenter.default.post(name: .offerActionFailed, object: error.localizedDescription)
            }
            return false
        }
    }

    private func routeToPostedJob(jobID: String, type: String) async {
        await MainActor.run {
            let defaults = UserDefaults.standard
            defaults.set(PushRoute.postedJobDestination, forKey: PushRoute.destinationKey)
            defaults.set(type, forKey: PushRoute.actionKey)
            defaults.set(jobID, forKey: PushRoute.jobIDKey)
            NotificationCenter.default.post(name: .pushRouteChanged, object: jobID)
        }
    }

    private func routeToJobs(jobID: String?, action: String) async {
        await MainActor.run {
            let defaults = UserDefaults.standard
            defaults.set("jobs", forKey: PushRoute.destinationKey)
            defaults.set(action, forKey: PushRoute.actionKey)
            if let jobID {
                defaults.set(jobID, forKey: PushRoute.jobIDKey)
            }
            NotificationCenter.default.post(name: .pushRouteChanged, object: jobID)
        }
    }
}

enum PushRegistration {
    static let deviceTokenKey = "pushDeviceToken"
}

enum PushRoute {
    static let destinationKey = "pendingPushDestination"
    static let actionKey = "pendingPushAction"
    static let jobIDKey = "pendingPushJobID"
    /// Destination for poster alerts; the action key then holds the push `type`.
    static let postedJobDestination = "postedJob"
}

extension Notification.Name {
    static let didRegisterPushToken = Notification.Name("didRegisterPushToken")
    static let pushRegistrationFailed = Notification.Name("pushRegistrationFailed")
    static let pushRouteChanged = Notification.Name("pushRouteChanged")
    static let offerDeclined = Notification.Name("offerDeclined")
    static let offerActionFailed = Notification.Name("offerActionFailed")
}
