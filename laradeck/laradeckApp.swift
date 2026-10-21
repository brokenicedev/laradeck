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
    @State private var appState = AppState()

    init() {
        appDelegate.appState = appState
    }

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environment(appState)
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

        MenuBarExtra("Laradeck", image: "MenuBarIcon") {
            MenuBarView()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
