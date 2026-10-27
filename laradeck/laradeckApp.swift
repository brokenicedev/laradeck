//
//  laradeckApp.swift
//  laradeck
//
//  Created by Luca Becchetti on 28/08/26.
//

import SwiftUI

@main
struct laradeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Built once per process: SwiftUI may initialize the `App` struct more than once, and a
    /// second `AppState` would re-run launch work (log tails, auto-start, dump servers).
    private static let sharedAppState = AppState()
    @State private var appState = laradeckApp.sharedAppState

    init() {
        appDelegate.appState = appState
    }

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environment(appState)
                .appThemed()
        }
        .defaultSize(width: 980, height: 640)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Laradeck") {
                    AboutPanel.show()
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    NotificationCenter.default.post(name: .laradeckCheckForUpdates, object: nil)
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("About Laradeck") {
                    AboutPanel.show()
                }
                Divider()
                Link("Star Laradeck on GitHub", destination: AppLinks.githubRepository)
                Link("Documentation", destination: AppLinks.githubReadme)
                Link("Report an Issue", destination: AppLinks.githubIssues)
                Divider()
                Link("brokenice.it", destination: AppLinks.brokenice)
            }
        }

        Window("Dumps", id: DumpsWindow.id) {
            DetachedDumpsWindow()
                .environment(appState)
                .appThemed()
        }
        .defaultSize(width: 760, height: 620)

        MenuBarExtra("Laradeck", image: "MenuBarIcon") {
            MenuBarView()
                .environment(appState)
                .appThemed()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appState)
                .appThemed()
        }
    }
}
