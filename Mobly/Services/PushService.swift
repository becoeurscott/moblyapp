import Foundation
import UIKit
import UserNotifications
import Combine

/// Push notifications: permission, APNs token registration, and taps.
///
/// Permission is **not** requested at launch. iOS gives an app exactly one
/// chance at the system prompt — refuse it and the only way back is Settings,
/// which almost nobody does. So the ask is deferred until the user has done
/// something that makes notifications obviously useful (sending their first
/// message), where the yes-rate is far higher.
@MainActor
final class PushService: NSObject, ObservableObject {
    static let shared = PushService()

    enum Status { case unknown, notDetermined, denied, authorized }
    @Published private(set) var status: Status = .unknown

    /// Thread to open, set when a notification is tapped.
    @Published var pendingThreadId: String?

    private var deviceToken: String?
    private let askedKey = "pushPromptShown"

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func refreshStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        status = {
            switch settings.authorizationStatus {
            case .notDetermined: return .notDetermined
            case .denied: return .denied
            case .authorized, .provisional, .ephemeral: return .authorized
            @unknown default: return .unknown
            }
        }()
        // Already granted (e.g. from a previous launch) — re-register, since
        // APNs can reissue the token after a restore or OS upgrade.
        if status == .authorized { UIApplication.shared.registerForRemoteNotifications() }
    }

    /// Ask once, at a moment where the value is obvious.
    /// Silently no-ops if already asked, granted, or refused.
    func requestIfAppropriate() async {
        await refreshStatus()
        guard status == .notDetermined,
              !UserDefaults.standard.bool(forKey: askedKey) else { return }
        UserDefaults.standard.set(true, forKey: askedKey)

        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        status = granted ? .authorized : .denied
        if granted { UIApplication.shared.registerForRemoteNotifications() }
    }

    // MARK: - Token

    /// Called from the app delegate once APNs issues a token.
    func register(deviceToken data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
        Task { await sync() }
    }

    /// Send the token to the backend. Requires a session, so it's retried after
    /// sign-in for the common case where the token arrives first.
    func sync() async {
        guard let deviceToken, MoblyAPI.shared.isAuthenticated else { return }
        struct Body: Encodable {
            let pushToken: String
            let platform: String
            let appVersion: String?
            let locale: String?
        }
        let version = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        _ = try? await MoblyAPI.shared.request(
            "devices", method: "POST",
            body: Body(pushToken: deviceToken, platform: "ios",
                       appVersion: version, locale: Locale.current.identifier),
            authorized: true
        ) as EmptyResponse
    }

    /// Detach this device on sign-out so the next person doesn't receive the
    /// previous user's notifications.
    func unregister() async {
        guard let deviceToken else { return }
        struct Body: Encodable { let pushToken: String }
        _ = try? await MoblyAPI.shared.request(
            "devices", method: "DELETE", body: Body(pushToken: deviceToken),
            authorized: true, retries: 0
        ) as EmptyResponse
        await clearBadge()
    }

    func clearBadge() async {
        try? await UNUserNotificationCenter.current().setBadgeCount(0)
    }
}

extension PushService: UNUserNotificationCenterDelegate {
    /// Chat messages suppress the banner (the socket already delivered them);
    /// everything else (re-engagement, visits, announcements) shows a full alert.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        let isChat = info["threadId"] != nil
        return isChat ? [.badge, .sound] : [.banner, .badge, .sound]
    }

    /// Tapped — remember the thread so the UI can open it once it's ready.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        if let threadId = info["threadId"] as? String {
            await MainActor.run { PushService.shared.pendingThreadId = threadId }
        }
    }
}

/// APNs callbacks only reach a `UIApplicationDelegate`, which SwiftUI wires up
/// through `@UIApplicationDelegateAdaptor`.
final class MoblyAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushService.shared.register(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Expected on a simulator without a paired push environment; a real
        // device failing here means the entitlement or provisioning is wrong.
        print("[push] APNs registration failed: \(error.localizedDescription)")
    }
}
