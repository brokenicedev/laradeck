import Foundation
import UserNotifications
import Observation

/// Delivers local system notifications for process and Docker events.
@MainActor
@Observable
final class NotificationManager {
    private enum Keys {
        static let enabled = "notificationsEnabled"
        static let processFailures = "notificationsProcessFailures"
        static let processActivity = "notificationsProcessActivity"
        static let processStarted = "notificationsProcessStarted"
        static let dockerFailures = "notificationsDockerFailures"
    }

    var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: Keys.enabled) }
    }

    var notifyProcessFailures: Bool {
        didSet { UserDefaults.standard.set(notifyProcessFailures, forKey: Keys.processFailures) }
    }

    /// Start/stop toasts for manual play and Start All / Stop All.
    var notifyProcessActivity: Bool {
        didSet { UserDefaults.standard.set(notifyProcessActivity, forKey: Keys.processActivity) }
    }

    var notifyDockerFailures: Bool {
        didSet { UserDefaults.standard.set(notifyDockerFailures, forKey: Keys.dockerFailures) }
    }

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.enabled) != nil {
            notificationsEnabled = defaults.bool(forKey: Keys.enabled)
        } else {
            notificationsEnabled = true
        }
        notifyProcessFailures = (defaults.object(forKey: Keys.processFailures) as? Bool) ?? true
        if defaults.object(forKey: Keys.processActivity) != nil {
            notifyProcessActivity = defaults.bool(forKey: Keys.processActivity)
        } else {
            notifyProcessActivity = (defaults.object(forKey: Keys.processStarted) as? Bool) ?? true
        }
        notifyDockerFailures = (defaults.object(forKey: Keys.dockerFailures) as? Bool) ?? true
    }

    /// Refreshes permission state and prompts once on first launch when notifications are enabled.
    func prepareOnLaunch() async {
        await refreshAuthorizationStatus()
        if notificationsEnabled, authorizationStatus == .notDetermined {
            await requestAuthorization()
        }
    }

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await refreshAuthorizationStatus()
            return granted
        } catch {
            await refreshAuthorizationStatus()
            return false
        }
    }

    func notifyProcessStarted(processName: String) {
        guard notifyProcessActivity else { return }
        notify(title: processName, body: "is running.")
    }

    func notifyProcessStopped(processName: String) {
        guard notifyProcessActivity else { return }
        notify(title: processName, body: "was stopped.")
    }

    func notifyAllProcessesStarted(projectName: String) {
        guard notifyProcessActivity else { return }
        notify(title: projectName, body: "All processes started.")
    }

    func notifyAllProcessesStartedWithFailures(projectName: String, failedProcessNames: [String]) {
        guard notifyProcessActivity || notifyProcessFailures else { return }
        let uniqueNames = Array(Set(failedProcessNames)).sorted()
        let list: String
        switch uniqueNames.count {
        case 0:
            list = "one or more processes"
        case 1:
            list = uniqueNames[0]
        case 2:
            list = "\(uniqueNames[0]) and \(uniqueNames[1])"
        default:
            list = "\(uniqueNames[0]), \(uniqueNames[1]), and \(uniqueNames.count - 2) more"
        }
        notify(title: projectName, body: "Start finished with errors — \(list) failed.")
    }

    func notifyAllProcessesStopped(projectName: String) {
        guard notifyProcessActivity else { return }
        notify(title: projectName, body: "All processes stopped.")
    }

    func notifyProcessUnexpectedExit(projectName: String, processName: String, exitCode: Int32) {
        guard notifyProcessFailures else { return }
        notify(
            title: processName,
            body: "Stopped unexpectedly (exit code \(exitCode))."
        )
    }

    func notifyProcessRestartLoop(projectName: String, processName: String) {
        guard notifyProcessFailures else { return }
        notify(
            title: processName,
            body: "Stuck in a restart loop and was stopped."
        )
    }

    func notifyProcessStartFailure(projectName: String, processName: String, reason: String) {
        guard notifyProcessFailures else { return }
        notify(title: processName, body: "Failed to start: \(reason)")
    }

    func notifyDockerFailure(projectName: String, message: String) {
        guard notifyDockerFailures else { return }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty ? "Docker command failed." : String(trimmed.prefix(240))
        notify(title: projectName, body: "Sail/Docker: \(body)")
    }

    func notifyDatabaseStartFailed(projectName: String, message: String) {
        guard notifyProcessFailures else { return }
        notify(title: projectName, body: "Database didn't start: \(String(message.prefix(240)))")
    }

    func notifyArtisanTaskSucceeded(projectName: String, message: String) {
        guard notifyProcessActivity else { return }
        notify(title: projectName, body: message)
    }

    func notifyArtisanTaskFailed(projectName: String, taskName: String, reason: String) {
        guard notifyProcessFailures else { return }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.isEmpty ? "\(taskName) failed." : String(trimmed.prefix(240))
        notify(title: projectName, body: "\(taskName): \(body)")
    }

    private func notify(title: String, body: String) {
        guard notificationsEnabled else { return }

        Task {
            await refreshAuthorizationStatus()
            guard authorizationStatus == .authorized else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}
