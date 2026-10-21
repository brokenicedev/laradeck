import AppKit
import SwiftUI

/// Dashboard warning when the project's Node (pinned or nvm default) doesn't satisfy its
/// `.nvmrc` / `.node-version` / `engines.node`, plus the restart notice after a change.
struct ProjectNodeBanner: View {
    @Environment(AppState.self) private var appState
    let project: Project

    private var node: NodeManager { appState.nodeManager }

    var body: some View {
        if let mismatch = node.mismatch(for: project) {
            HStack(alignment: .center, spacing: 10) {
                NoticeBanner(tone: .warning, message: message(mismatch))
                if let target = mismatch.suggestion {
                    Button("Use Node \(target.version.description)") {
                        appState.setNodeVersion(target, for: project)
                    }
                    .help("Only \(project.name)'s processes use this version; the nvm default stays as it is")
                    .buttonStyle(.borderedProminent)
                } else {
                    let hint = mismatch.requirement.requirement.installHint
                    Button("Install Node \(hint)") {
                        Task {
                            if await node.install(hint),
                               let best = node.mismatch(for: project)?.suggestion {
                                appState.setNodeVersion(best, for: project)
                            }
                        }
                    }
                    .help("Runs nvm install \(hint), then uses it for \(project.name)")
                    .buttonStyle(.borderedProminent)
                    .disabled(node.busy != nil)
                }
                if node.busy != nil { ProgressView().controlSize(.small) }
            }
        }
        if let error = node.error {
            HStack(spacing: 10) {
                NoticeBanner(tone: .error, message: error)
                Button("Dismiss") { node.error = nil }
            }
        }
        if node.pendingRestart.contains(project.id) {
            if appState.runningNodeProcesses(in: project).isEmpty {
                Color.clear.frame(height: 0).onAppear { node.pendingRestart.remove(project.id) }
            } else {
                HStack(spacing: 10) {
                    NoticeBanner(tone: .info,
                                 message: "Running npm processes still use the previous Node version until restarted.")
                    Button("Restart") { appState.restartNodeProcesses(in: project) }
                        .buttonStyle(.borderedProminent)
                    Button("Later") { node.pendingRestart.remove(project.id) }
                }
            }
        }
    }

    private func message(_ mismatch: ProjectNodeMismatch) -> String {
        let required = "\(project.name) requires Node \(mismatch.requirement.requirement.description) (\(mismatch.requirement.source.rawValue))"
        var text: String
        if let current = mismatch.current {
            let origin = mismatch.isPinned ? "chosen for this project" : "the nvm default"
            text = "\(required), but it runs with Node \(current.version.description), \(origin)."
        } else {
            text = "\(required), but nvm has no default version."
        }
        if mismatch.suggestion == nil { text += " No installed version fits." }
        return text
    }
}

/// Header item showing the project's Node version; the menu picks another installed version.
struct ProjectNodeMenu: View {
    @Environment(AppState.self) private var appState
    let project: Project

    private var node: NodeManager { appState.nodeManager }

    var body: some View {
        if node.isNvmInstalled, project.environment == .native, !node.installed.isEmpty {
            let pinned = node.pinned(for: project)
            let current = node.current(for: project)
            Menu {
                Button {
                    appState.setNodeVersion(nil, for: project)
                } label: {
                    if pinned == nil { Image(systemName: "checkmark") }
                    Text("nvm default" + (node.defaultInstallation.map { " (\($0.version.description))" } ?? ""))
                }
                Divider()
                ForEach(node.installed) { installation in
                    Button {
                        appState.setNodeVersion(installation, for: project)
                    } label: {
                        if pinned == installation { Image(systemName: "checkmark") }
                        Text("Node \(installation.version.description)")
                    }
                }
            } label: {
                Label(current.map { "Node \($0.version.description)" } ?? "Node", systemImage: "hexagon")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help(pinned != nil
                  ? "Node version used by this project's processes (nvm)"
                  : "Uses the nvm default; pick a version for this project only")
        }
    }
}
