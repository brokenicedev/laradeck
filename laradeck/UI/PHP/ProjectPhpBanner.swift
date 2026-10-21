import PhpSwitcherCore
import SwiftUI

/// Dashboard warning when the linked Homebrew PHP doesn't satisfy composer.json's `require.php`.
struct ProjectPhpBanner: View {
    @Environment(AppState.self) private var appState
    let project: Project

    private var php: PhpManager { appState.phpManager }

    var body: some View {
        if let mismatch = php.mismatch(for: project) {
            HStack(alignment: .center, spacing: 10) {
                NoticeBanner(tone: .warning, message: message(mismatch))
                if let target = mismatch.suggestion {
                    if let site = php.valetSite(at: project.path) {
                        Button("Isolate to PHP \(target.version.short)") {
                            Task { await php.isolate(site, to: target) }
                        }
                        .help("valet isolate: only \(site.domain) uses PHP \(target.version.short); the global PHP stays as it is")
                        .disabled(php.busy != nil)
                    }
                    Button("Switch to PHP \(target.version.short)") {
                        Task { await php.switchTo(target) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(php.busy != nil)
                } else {
                    Button("Install PHP…") { appState.showingPhp = true }
                }
                if php.busy != nil { ProgressView().controlSize(.small) }
            }
        }
        if php.pendingProcessRestart, !appState.runningHostPhpProcesses.isEmpty {
            PhpStatusBanners()
        }
    }

    private func message(_ mismatch: ProjectPhpMismatch) -> String {
        var text = "\(project.name) requires PHP \(mismatch.constraint), but PHP \(mismatch.active) is linked."
        if mismatch.suggestion == nil { text += " No installed version fits." }
        return text
    }
}
