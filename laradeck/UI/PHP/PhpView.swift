import AppKit
import PhpSwitcherCore
import SwiftUI

enum PhpPageTab: String, CaseIterable, Identifiable {
    case versions = "Versions"
    case extensions = "Extensions"
    case configuration = "Configuration"
    case services = "Services"
    case valet = "Valet"
    case composer = "Composer"
    var id: String { rawValue }
}

/// Detail page for the sidebar's "PHP" row: Homebrew PHP versions, extensions,
/// php.ini, services, Valet sites and Composer (ported from phpmonit / PHP Monitor).
/// Same layout as the other detail pages: full-width scroll view with card sections.
struct PhpView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("phpPageSection") private var tab: PhpPageTab = .versions

    private var php: PhpManager { appState.phpManager }

    private var tabs: [PhpPageTab] {
        PhpPageTab.allCases.filter {
            switch $0 {
            case .valet: return php.usesValet
            case .composer: return php.isComposerInstalled
            default: return true
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if !php.isHomebrewInstalled {
                    NoticeBanner(tone: .info, message: "PHP versions are managed with Homebrew. Install it from brew.sh.")
                } else {
                    Picker("Section", selection: $tab) {
                        ForEach(tabs) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    switch tabs.contains(tab) ? tab : .versions {
                    case .versions: PhpVersionsTab()
                    case .extensions: PhpExtensionsTab()
                    case .configuration: PhpConfigurationTab()
                    case .services: PhpServicesTab()
                    case .valet: PhpValetTab()
                    case .composer: PhpComposerTab()
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LaradeckTheme.pageBackground)
        .laradeckTitle("PHP")
        .detailCloseButton(help: "Close PHP") { appState.showingPhp = false }
        .toolbar {
            ToolbarItem {
                Button {
                    php.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Reload PHP state")
                .disabled(php.busy != nil)
            }
        }
        .onAppear { php.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.indigo)
                    .frame(width: 44, height: 44)
                    .background(.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(php.active.map { "PHP \($0.version.description)" } ?? (php.loaded ? "No PHP linked" : "PHP"))
                        .font(.title.weight(.semibold))
                    Text(php.active.map { "\($0.formula) · linked in Homebrew" } ?? "Pick a version to link it")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let busy = php.busy {
                    ProgressView().controlSize(.small)
                    Text(busy)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 360, alignment: .trailing)
                }
            }
            PhpStatusBanners()
        }
    }
}

/// Error, last result and "restart processes" notices, shared by the page and the toolbar popover.
struct PhpStatusBanners: View {
    @Environment(AppState.self) private var appState
    private var php: PhpManager { appState.phpManager }

    var body: some View {
        if let error = php.error {
            NoticeBanner(tone: .error, message: error) { php.error = nil }
        } else if let message = php.lastMessage {
            NoticeBanner(tone: .success, message: message) { php.lastMessage = nil }
        }
        let stale = appState.runningHostPhpProcesses
        if php.pendingProcessRestart, !stale.isEmpty {
            HStack {
                NoticeBanner(tone: .warning,
                             message: "\(stale.count) running process\(stale.count == 1 ? "" : "es") still use the previous PHP: \(stale.map(\.definition.name).joined(separator: ", "))")
                Button("Restart") {
                    appState.restartHostPhpProcesses()
                    php.pendingProcessRestart = false
                }
                Button("Later") { php.pendingProcessRestart = false }
            }
        }
    }
}

/// Small icon-only "…" menu used in rows.
private struct RowMenu<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private func emptyRow(_ text: String) -> some View {
    Text(text).foregroundStyle(.secondary).detailRow()
}

// MARK: - Versions

private struct PhpVersionsTab: View {
    @Environment(AppState.self) private var appState
    @State private var confirmUninstall: String?
    @State private var confirmInstall: String?
    private var php: PhpManager { appState.phpManager }

    var body: some View {
        let formulae = php.snapshot.phpFormulae
        let available = formulae.filter { !$0.installed }
        VStack(alignment: .leading, spacing: 20) {
            DetailSection("Installed",
                          footer: "Switching unlinks every Homebrew PHP and links the one you pick (brew link), like PHP Monitor.") {
                Button(php.checkedOutdated ? "Check Again" : "Check for Updates") { php.checkForUpdates() }
                    .buttonStyle(.link)
                    .disabled(php.busy != nil)
            } content: {
                ForEach(php.installed) { installation in
                    let status = formulae.first { $0.formula == installation.formula }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("PHP \(installation.version.description)")
                            Text(installation.formula)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if status?.outdated == true {
                            Text("Update available")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        if php.isActive(installation) {
                            Label("Active", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Button("Switch") { Task { await php.switchTo(installation) } }
                                .disabled(php.busy != nil)
                        }
                        RowMenu {
                            if status?.outdated == true {
                                Button("Upgrade") { php.upgradeVersion(installation.formula) }
                            }
                            Button("Uninstall…", role: .destructive) { confirmUninstall = installation.formula }
                                .disabled(php.isActive(installation))
                        }
                        .disabled(php.busy != nil)
                    }
                    .detailRow()
                }
                if php.installed.isEmpty && php.loaded {
                    emptyRow("No Homebrew PHP versions found.")
                }
            }

            DetailSection("Available") {
                if available.isEmpty {
                    emptyRow("Add the shivammathur/php tap to install other versions: brew tap shivammathur/php")
                        .textSelection(.enabled)
                }
                ForEach(available) { formula in
                    HStack {
                        Text("PHP \(formula.version)")
                        Spacer()
                        Button("Install…") { confirmInstall = formula.formula }
                            .disabled(php.busy != nil)
                    }
                    .detailRow()
                }
            }
        }
        .confirmationDialog("Uninstall \(confirmUninstall ?? "")?", isPresented: Binding(
            get: { confirmUninstall != nil }, set: { if !$0 { confirmUninstall = nil } }
        )) {
            Button("Uninstall", role: .destructive) {
                if let formula = confirmUninstall { php.uninstallVersion(formula) }
            }
        } message: {
            Text("Runs brew uninstall --force. Its configuration in etc/php stays.")
        }
        .confirmationDialog("Install \(confirmInstall ?? "")?", isPresented: Binding(
            get: { confirmInstall != nil }, set: { if !$0 { confirmInstall = nil } }
        )) {
            Button("Install") {
                if let formula = confirmInstall { php.installVersion(formula) }
            }
        } message: {
            Text("Installs from the shivammathur/php tap. This can take several minutes.")
        }
    }
}

// MARK: - Configuration

private struct PhpConfigurationTab: View {
    @Environment(AppState.self) private var appState
    @State private var drafts: [String: String] = [:]
    private var php: PhpManager { appState.phpManager }

    var body: some View {
        let snapshot = php.snapshot
        VStack(alignment: .leading, spacing: 20) {
            if let limits = snapshot.limits {
                DetailSection("Limits",
                              footer: "Sizes like 256M or 1G, or -1 for unlimited. Saved in the .ini file that defines them.") {
                    limitRow("memory_limit", limits.memoryLimit)
                    limitRow("post_max_size", limits.postMaxSize)
                    limitRow("upload_max_filesize", limits.uploadMaxFilesize)
                }
            }

            DetailSection("Files") {
                if let config = php.config() {
                    fileRow("php.ini", action: "Open") { NSWorkspace.shared.open(URL(fileURLWithPath: config.phpIni)) }
                    fileRow("conf.d", action: "Open Folder") { NSWorkspace.shared.open(URL(fileURLWithPath: config.confD)) }
                }
                if let log = snapshot.errorLog {
                    fileRow("Error log", action: "Open in Console") {
                        NSWorkspace.shared.open([URL(fileURLWithPath: log)],
                                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
                                                configuration: NSWorkspace.OpenConfiguration())
                    }
                }
                fileRow("phpinfo()", action: "Show") { php.openPhpInfo() }
                    .disabled(php.busy != nil || php.active == nil)
            }

            if !snapshot.iniFiles.isEmpty {
                DetailSection("Loaded .ini files") {
                    ForEach(snapshot.iniFiles, id: \.self) { file in
                        HStack {
                            Text(file)
                                .font(.callout.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)])
                            } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .buttonStyle(.borderless)
                            .help("Show in Finder")
                        }
                        .detailRow()
                    }
                }
            }
        }
    }

    private func fileRow(_ title: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button(action, action: perform)
        }
        .detailRow()
    }

    private func limitRow(_ key: String, _ current: String) -> some View {
        HStack(spacing: 6) {
            Text(key).font(.body.monospaced())
            Spacer()
            TextField(key, text: Binding(
                get: { drafts[key] ?? current },
                set: { drafts[key] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 90)
            .onSubmit { commit(key, current) }
            Menu {
                ForEach(["128M", "256M", "512M", "1G", "2G", "-1"], id: \.self) { preset in
                    Button(preset == "-1" ? "Unlimited (-1)" : preset) {
                        drafts[key] = nil
                        php.setLimit(key, preset)
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .disabled(php.busy != nil)
        .detailRow()
    }

    private func commit(_ key: String, _ current: String) {
        guard let value = drafts[key], value != current else { return }
        drafts[key] = nil
        php.setLimit(key, value)
    }
}

// MARK: - Services

private struct PhpServicesTab: View {
    @Environment(AppState.self) private var appState
    private var php: PhpManager { appState.phpManager }

    var body: some View {
        DetailSection("Homebrew services",
                      footer: php.usesValet
                          ? "With Valet these run as root via sudo brew services. If they fail, run `valet trust` once in Terminal."
                          : "PHP-FPM via brew services. Laravel's own server (php artisan serve) doesn't need it.") {
            ForEach(php.keyServices, id: \.name) { service in
                HStack {
                    StatusDotView(color: service.isRunning ? .green : (service.hasError ? .red : .gray), size: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(service.name)
                        Text(service.isRunning ? "Running" : (service.status ?? "Not running"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if service.isRunning {
                        Button("Restart") { php.service(.restart, service.name) }
                        Button("Stop") { php.service(.stop, service.name) }
                    } else {
                        Button("Start") { php.service(.start, service.name) }
                    }
                }
                .disabled(php.busy != nil)
                .detailRow()
            }
            if php.keyServices.isEmpty {
                emptyRow("No PHP linked.")
            }
        }
    }
}

// MARK: - Composer

private struct PhpComposerTab: View {
    @Environment(AppState.self) private var appState
    private var php: PhpManager { appState.phpManager }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            DetailSection("Composer", footer: "Runs composer global update (Laravel installer, Valet, …).") {
                HStack {
                    Text("Global packages")
                    Spacer()
                    Button("Update") { php.composerGlobalUpdate() }
                        .disabled(php.busy != nil)
                }
                .detailRow()
            }
            if let output = php.composerOutput {
                DetailSection("Output") {
                    ScrollView {
                        Text(output)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .defaultScrollAnchor(.bottom)
                    .frame(height: 220)
                }
            }
        }
    }
}
