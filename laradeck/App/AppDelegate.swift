import AppKit
import UserNotifications

/// Hooks into AppKit's termination lifecycle — SwiftUI's `App` protocol has no equivalent, and
/// without this every process Laradeck started is orphaned on quit instead of being stopped.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in
            await appState?.notificationManager.prepareOnLaunch()
        }
    }

    /// Run cleanup before the app begins tearing down UI — more reliable than only using
    /// `applicationWillTerminate` when multiple workers must be signalled.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        appState?.processManager.stopAllProcessesForAppTermination()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Belt-and-suspenders if something started between shouldTerminate and now.
        appState?.processManager.stopAllProcessesForAppTermination()
    }

    /// Show banners and play sounds even when Laradeck is the frontmost app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
