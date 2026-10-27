import SwiftUI
import AppKit
import UserNotifications

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        @Bindable var notificationManager = appState.notificationManager
        @Bindable var databaseManager = appState.databaseManager

        TabView {
            Form {
                Toggle("Launch at Login", isOn: $appState.launchAtLogin)
                Toggle("Confirm Before Stop All", isOn: $appState.confirmBeforeStopAll)
                MenuPicker(
                    "Terminal",
                    selection: $appState.preferredTerminal,
                    options: TerminalLauncher.installedTerminals().map { ($0, $0.displayName) }
                )
                Toggle("Start Databases When Laradeck Opens", isOn: $databaseManager.startOnLaunch)
                    .help("Starts the databases marked \"Start When Laradeck Opens\". Databases keep running after you quit Laradeck, but not after you log out.")

                Section {
                    updatesSection
                } header: {
                    Text("Updates")
                } footer: {
                    Text(updatesFooter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Enable Notifications", isOn: $notificationManager.notificationsEnabled)
                        .onChange(of: notificationManager.notificationsEnabled) { _, enabled in
                            if enabled {
                                Task { await notificationManager.requestAuthorization() }
                            }
                        }

                    if notificationManager.notificationsEnabled {
                        Toggle("Process start & stop", isOn: $notificationManager.notifyProcessActivity)
                        Toggle("Process failures", isOn: $notificationManager.notifyProcessFailures)
                        Toggle("Docker / Sail errors", isOn: $notificationManager.notifyDockerFailures)
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    notificationsFooter(notificationManager)
                }
            }
            .padding(20)
            .tabItem { Label("General", systemImage: "gearshape") }

            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }

            DumpsSettingsView()
                .tabItem { Label("Dumps", systemImage: "ladybug") }

            CommandsSettingsView()
                .tabItem { Label("Commands", systemImage: "terminal") }
        }
        .frame(width: 520, height: 460)
        .task {
            await notificationManager.refreshAuthorizationStatus()
        }
    }

    @ViewBuilder
    private var updatesSection: some View {
        let versionCheck = appState.versionCheck
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Current version")
                Text(LocalAppVersion.current.marketing)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            Spacer()
            Button {
                Task { await versionCheck.checkForUpdates(userInitiated: true) }
            } label: {
                Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.laradeckOutline)
            .disabled({
                if case .checking = versionCheck.status { return true }
                return false
            }())
        }

        #if SPARKLE
        Toggle(
            "Automatically check for updates",
            isOn: Binding(
                get: { SparkleUpdaterController.shared.automaticallyChecksForUpdates },
                set: { SparkleUpdaterController.shared.automaticallyChecksForUpdates = $0 }
            )
        )
        #endif

        switch versionCheck.status {
        case .idle:
            EmptyView()
        case .checking:
            Label("Checking…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .upToDate:
            Label("You're up to date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .updateAvailable(let info):
            VStack(alignment: .leading, spacing: 8) {
                Label("Version \(info.latest) is available", systemImage: "arrow.down.app.fill")
                    .font(.caption)
                HStack {
                    Button {
                        versionCheck.openUpdate()
                    } label: {
                        Label(
                            AppDistributionChannel.current == .appStore ? "Open App Store" : "Update",
                            systemImage: "arrow.down.app.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button {
                        versionCheck.skipThisVersion()
                    } label: {
                        Label("Skip This Version", systemImage: "forward")
                    }
                    .buttonStyle(.laradeckOutline)
                    .controlSize(.small)
                }
            }
        case .failed(let message):
            NoticeBanner(tone: .warning, message: message)
        }
    }

    private var updatesFooter: String {
        switch AppDistributionChannel.current {
        case .appStore:
            return "Laradeck checks a version feed on launch. Install updates from the Mac App Store."
        case .direct:
            #if SPARKLE
            return "Laradeck checks for updates in the background. Sparkle installs direct (Developer ID) builds."
            #else
            return "Laradeck checks a version feed on launch and can open the download page when an update is available."
            #endif
        }
    }

    @ViewBuilder
    private func notificationsFooter(_ notificationManager: NotificationManager) -> some View {
        switch notificationManager.authorizationStatus {
        case .authorized:
            Text("Single play/stop shows the process name; Start All / Stop All shows the project name.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .denied:
            VStack(alignment: .leading, spacing: 6) {
                Text("Notifications are blocked in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    openNotificationSettings()
                } label: {
                    Label("Open Notification Settings", systemImage: "bell.badge")
                }
                .buttonStyle(.laradeckOutline)
                .controlSize(.small)
            }
        case .notDetermined:
            Text("Laradeck will ask for permission the first time notifications are enabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private func openNotificationSettings() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let urlString = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct CommandsSettingsView: View {
    @State private var resolvedPaths: [String: String] = [:]
    @State private var overridePaths: [String: String] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(RuntimeResolver.knownTools, id: \.self) { tool in
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Override path", text: Binding(
                            get: { overridePaths[tool] ?? "" },
                            set: { newValue in
                                overridePaths[tool] = newValue
                                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                                RuntimeResolver.shared.setOverride(trimmed.isEmpty ? nil : trimmed, for: tool)
                                Task { await refreshResolved(for: tool) }
                            }
                        ), prompt: Text(tool))
                        .font(.system(.body, design: .monospaced))

                        Text("Detected: \(resolvedPaths[tool] ?? "Resolving…")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let resolved = resolvedPaths[tool],
                           resolved != "Resolving…",
                           resolved != "Not found",
                           FileManager.default.fileExists(atPath: resolved) {
                            PathLinkButton(path: (resolved as NSString).deletingLastPathComponent, lineLimit: 1)
                        }
                    }
                }
            } header: {
                Text("Tool Paths")
            } footer: {
                Text("Leave override empty to use auto-detection from Homebrew and your login shell PATH.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .task {
            let saved = RuntimeResolver.shared.allOverrides()
            for tool in RuntimeResolver.knownTools {
                overridePaths[tool] = saved[tool] ?? ""
                await refreshResolved(for: tool)
            }
        }
    }

    private func refreshResolved(for tool: String) async {
        resolvedPaths[tool] = await RuntimeResolver.shared.resolvePath(for: tool) ?? "Not found"
    }
}
