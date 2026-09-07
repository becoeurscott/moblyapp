import SwiftUI

@main
struct MoblyApp: App {
    // APNs callbacks only reach a UIApplicationDelegate.
    @UIApplicationDelegateAdaptor(MoblyAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        MoblyFonts.registerBundledFonts()
        MoblyImageCache.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.light)
                // Text scales with the system setting, but stops at xxLarge.
                //
                // The layouts are built for fixed sizes: past this point rows
                // clip and the auth toggle overflows. Capping keeps most of the
                // accessibility benefit — text still grows noticeably for
                // anyone who needs it — without shipping broken screens. Raise
                // or remove this once the per-screen wrapping work is done.
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                // Confirm any stored session with the server before the UI
                // trusts it — a Keychain token may have been revoked since.
                .task {
                    // Analytics session first so events during bootstrap
                    // (auth restore, first screen view) attach to it.
                    await SessionTracker.shared.start()
                    // Ask whether the app is in a maintenance window before
                    // anything else fans out — a user opening during a window
                    // should meet the maintenance screen, not a home feed that
                    // fails to load piece by piece.
                    await MaintenanceStore.shared.checkAtLaunch()
                    // Then the remote configuration: which features are on,
                    // the current limits and copy, and whether this build is
                    // still supported. Fetched before the UI settles so a
                    // disabled control is never briefly offered.
                    await RemoteConfigStore.shared.checkAtLaunch()
                    // Fetch listings early so the onboarding slides can render
                    // real properties from the DB instead of the bundled
                    // sample cards. Detached so it doesn't get cancelled with
                    // the SwiftUI .task if the user navigates away.
                    Task.detached { await ListingStore.shared.fetch(silent: true) }
                    await AuthStore.shared.bootstrap()
                    // If bootstrap surfaced a signed-in user, promote the
                    // anonymous session to their account.
                    if AuthStore.shared.isSignedIn {
                        await SessionTracker.shared.attach()
                    }
                    SessionTracker.shared.log("app.open", [
                        "signedIn": AuthStore.shared.isSignedIn
                    ])
                    LocationService.shared.requestIfNeeded()
                    await PushService.shared.refreshStatus()
                    // From here on the app keeps itself current on its own:
                    // silent polls + foreground + reconnect, no spinners.
                    LiveRefresh.shared.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Coming back to the foreground: re-sync the inbox and
                    // prewarm every thread's first page so any conversation
                    // opened next is instant. Skips fetches whose cache is
                    // fresh, so this is cheap on rapid switches. Also refresh
                    // notifications so the bell dot reflects any broadcast /
                    // event that landed while the app was in the background.
                    // Re-check maintenance on every foreground, signed in or
                    // not: a window may have opened (or been lifted) while the
                    // app sat in the background.
                    if phase == .active {
                        Task { await MaintenanceStore.shared.checkAtLaunch() }
                        // The socket does not survive suspension. Without this
                        // the app came back to a dead connection and messages
                        // arrived only when something happened to refetch.
                        ChatStore.shared.ensureConnected()
                        // Same reasoning for the configuration: a flag may have
                        // been flipped while the app sat in the background.
                        Task { await RemoteConfigStore.shared.refresh() }
                    }
                    if phase == .active, AuthStore.shared.isSignedIn {
                        Task {
                            await ChatStore.shared.loadThreads(silent: true)
                            await ChatStore.shared.prewarmAllThreads()
                            await UserDataStore.shared.loadNotifications()
                        }
                    }
                }
        }
    }
}
