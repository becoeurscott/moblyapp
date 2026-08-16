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
                    // Fetch listings early so the onboarding slides can render
                    // real properties from the DB instead of the bundled
                    // sample cards. Detached so it doesn't get cancelled with
                    // the SwiftUI .task if the user navigates away.
                    Task.detached { await ListingStore.shared.refresh() }
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
                }
                .onChange(of: scenePhase) { _, phase in
                    // Coming back to the foreground: re-sync the inbox and
                    // prewarm every thread's first page so any conversation
                    // opened next is instant. Skips fetches whose cache is
                    // fresh, so this is cheap on rapid switches. Also refresh
                    // notifications so the bell dot reflects any broadcast /
                    // event that landed while the app was in the background.
                    if phase == .active, AuthStore.shared.isSignedIn {
                        Task {
                            await ChatStore.shared.loadThreads()
                            await ChatStore.shared.prewarmAllThreads()
                            await UserDataStore.shared.loadNotifications()
                        }
                    }
                }
        }
    }
}
