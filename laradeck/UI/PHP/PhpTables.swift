import AppKit
import PhpSwitcherCore
import SwiftUI

/// Height for a `Table` inside a scrolling page: fits the rows, capped so the page stays usable.
private func tableHeight(rows: Int, rowHeight: CGFloat = 26, max: CGFloat = 520) -> CGFloat {
    min(Swift.max(CGFloat(rows) * rowHeight + 30, 110), max)
}

/// Headline + filter field above a table.
private struct TableHeader<Accessory: View>: View {
    let title: String
    @Binding var query: String
    let prompt: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.headline)
            accessory()
            Spacer()
            FilterField(prompt: prompt, text: $query)
        }
    }
}

// MARK: - Extensions

struct PhpExtensionsTab: View {
    @Environment(AppState.self) private var appState
    @State private var query = ""
    @State private var iniSort = [KeyPathComparator(\PhpExtension.name)]
    @State private var brewSort = [KeyPathComparator(\BrewExtension.name)]
    @State private var iniSelection: PhpExtension.ID?
    @State private var brewSelection: BrewExtension.ID?

    private var php: PhpManager { appState.phpManager }

    var body: some View {
        let snapshot = php.snapshot
        let iniRows = snapshot.extensions
            .filter { $0.name.matchesFilter(query) || $0.iniFile.matchesFilter(query) }
            .sorted(using: iniSort)
        let brewRows = snapshot.brewExtensions
            .filter { $0.name.matchesFilter(query) }
            .sorted(using: brewSort)

        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                TableHeader(title: "Enabled in php.ini", query: $query, prompt: "Filter extensions") {
                    if let mode = snapshot.xdebugMode {
                        Picker("Xdebug", selection: Binding(get: { mode }, set: { php.setXdebugMode($0) })) {
                            ForEach(Array(Set(PhpConfig.xdebugModes + [mode])).sorted(), id: \.self) { Text($0).tag($0) }
                        }
                        .fixedSize()
                        .disabled(php.busy != nil)
                        .help("xdebug.mode")
                    }
                }
                Table(iniRows, selection: $iniSelection, sortOrder: $iniSort) {
                    TableColumn("On") { (ext: PhpExtension) in
                        Toggle(ext.name, isOn: Binding(get: { ext.enabled }, set: { _ in php.toggle(ext) }))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .disabled(php.busy != nil)
                    }
                    .width(34)
                    TableColumn("Extension", value: \.name) { (ext: PhpExtension) in
                        Text(ext.name)
                            .foregroundStyle(ext.enabled ? .primary : .secondary)
                    }
                    .width(min: 120, ideal: 160)
                    TableColumn("Loaded from", value: \.iniFile) { (ext: PhpExtension) in
                        Text(ext.iniFile)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(ext.iniFile)
                    }
                }
                .contextMenu(forSelectionType: PhpExtension.ID.self) { ids in
                    if let ext = snapshot.extensions.first(where: { ids.contains($0.id) }) {
                        Button(ext.enabled ? "Disable \(ext.name)" : "Enable \(ext.name)") { php.toggle(ext) }
                        Button("Show .ini in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ext.iniFile)])
                        }
                    }
                }
                .frame(height: tableHeight(rows: iniRows.count))
                .overlay { emptyOverlay(iniRows.isEmpty, all: snapshot.extensions.isEmpty, noun: "extension lines in the loaded .ini files") }
                Text("Toggling comments or uncomments the extension line, then restarts PHP-FPM if it's running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Homebrew extensions for PHP \(php.active?.version.short ?? "")").font(.headline)
                    Spacer()
                    if snapshot.extensionTapInstalled {
                        Text("\(snapshot.brewExtensions.filter(\.installed).count) installed · \(snapshot.brewExtensions.count) available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !snapshot.extensionTapInstalled {
                    HStack {
                        Text("Extensions like xdebug, redis or imagick come from the shivammathur/extensions tap.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Add Tap") { php.installExtensionTap() }
                            .disabled(php.busy != nil)
                    }
                    .padding(12)
                    .laradeckCard()
                } else {
                    Table(brewRows, selection: $brewSelection, sortOrder: $brewSort) {
                        TableColumn("Extension", value: \.name) { (ext: BrewExtension) in
                            Text(ext.name)
                        }
                        .width(min: 140, ideal: 200)
                        TableColumn("Formula") { (ext: BrewExtension) in
                            Text(ext.formula)
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        TableColumn("Status") { (ext: BrewExtension) in
                            if ext.installed {
                                Label("Installed", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Text("Available").foregroundStyle(.secondary)
                            }
                        }
                        .width(110)
                        TableColumn("") { (ext: BrewExtension) in
                            if ext.installed {
                                Button("Remove", role: .destructive) { php.removeExtension(ext) }
                                    .controlSize(.small)
                            } else {
                                Button("Install") { php.installExtension(ext) }
                                    .controlSize(.small)
                            }
                        }
                        .width(80)
                    }
                    .disabled(php.busy != nil)
                    .frame(height: tableHeight(rows: brewRows.count))
                    .overlay { emptyOverlay(brewRows.isEmpty, all: snapshot.brewExtensions.isEmpty, noun: "extensions in the tap") }
                }
            }
        }
    }
}

// MARK: - Valet

extension ValetSite {
    /// Sort key / label for the PHP column: isolated version or "Global".
    var phpLabel: String { isolatedVersion.map { "Php \($0)" } ?? "Global" }
    var httpsLabel: String { secured ? "HTTPS" : "HTTP" }
}

struct PhpValetTab: View {
    @Environment(AppState.self) private var appState
    @State private var query = ""
    @State private var sortOrder = [KeyPathComparator(\ValetSite.domain)]
    @State private var selection: ValetSite.ID?

    private var php: PhpManager { appState.phpManager }

    var body: some View {
        let snapshot = php.snapshot
        let projects = projectsByPath
        let rows = snapshot.sites
            .filter { site in
                site.domain.matchesFilter(query) || site.path.matchesFilter(query)
                    || site.phpLabel.matchesFilter(query)
                    || (projects[site.path]?.name.matchesFilter(query) ?? false)
            }
            .sorted(using: sortOrder)

        VStack(alignment: .leading, spacing: 10) {
            TableHeader(title: snapshot.valetVersion.map { "Laravel Valet \($0)" } ?? "Laravel Valet",
                        query: $query, prompt: "Filter sites") {
                Text(query.isEmpty ? "\(snapshot.sites.count) sites" : "\(rows.count) of \(snapshot.sites.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Site", value: \.domain) { (site: ValetSite) in
                    HStack(spacing: 6) {
                        Image(systemName: site.secured ? "lock.fill" : "globe")
                            .foregroundStyle(site.secured ? .green : .secondary)
                            .frame(width: 14)
                        Text(site.domain)
                    }
                }
                .width(min: 160, ideal: 240)
                TableColumn("PHP", value: \.phpLabel) { (site: ValetSite) in
                    if site.isolatedVersion != nil {
                        Text(site.phpLabel)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.indigo.opacity(0.12), in: Capsule())
                    } else {
                        Text("Global").foregroundStyle(.secondary)
                    }
                }
                .width(80)
                TableColumn("HTTPS", value: \.httpsLabel) { (site: ValetSite) in
                    Text(site.secured ? "Secure" : "—")
                        .foregroundStyle(site.secured ? .green : .secondary)
                }
                .width(64)
                TableColumn("Path", value: \.path) { (site: ValetSite) in
                    Text(site.path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(site.path)
                }
                TableColumn("Project") { (site: ValetSite) in
                    if let project = projects[site.path] {
                        Button {
                            appState.selectedProjectId = project.id
                        } label: {
                            Label(project.name, systemImage: "arrow.right.circle")
                        }
                        .buttonStyle(.link)
                        .help("Open \(project.name) in Laradeck")
                    }
                }
                .width(min: 90, ideal: 130)
            }
            .contextMenu(forSelectionType: ValetSite.ID.self) { ids in
                if let site = snapshot.sites.first(where: { ids.contains($0.id) }) {
                    siteMenu(site)
                }
            } primaryAction: { ids in
                // Double-click opens the site in the browser.
                if let site = snapshot.sites.first(where: { ids.contains($0.id) }) {
                    NSWorkspace.shared.open(site.url)
                }
            }
            .frame(height: tableHeight(rows: rows.count, max: 640))
            .overlay { emptyOverlay(rows.isEmpty, all: snapshot.sites.isEmpty, noun: "Valet sites — park a folder with `valet park`") }

            Text("Double-click a site to open it. Right-click to secure it or isolate it to a PHP version without changing the global one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Projects keyed by their resolved path, to match Valet sites.
    private var projectsByPath: [String: Project] {
        Dictionary(appState.projects.map { (URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path, $0) },
                   uniquingKeysWith: { first, _ in first })
    }

    @ViewBuilder
    private func siteMenu(_ site: ValetSite) -> some View {
        Button("Open \(site.url.absoluteString)") { NSWorkspace.shared.open(site.url) }
        Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: site.path)) }
        Divider()
        Button(site.secured ? "Unsecure (HTTP)" : "Secure (HTTPS)") { php.setSecure(site, !site.secured) }
            .disabled(php.busy != nil)
        Menu("Isolate PHP Version") {
            ForEach(php.installed) { installation in
                Button {
                    Task { await php.isolate(site, to: installation) }
                } label: {
                    if site.isolatedVersion == installation.version.short {
                        Label("Php \(installation.version.short)", systemImage: "checkmark")
                    } else {
                        Text("Php \(installation.version.short)")
                    }
                }
            }
            if site.isolatedVersion != nil {
                Divider()
                Button("Use Global PHP") { Task { await php.isolate(site, to: nil) } }
            }
        }
        .disabled(php.busy != nil)
        if let project = projectsByPath[site.path] {
            Divider()
            Button("Show \(project.name) in Laradeck") { appState.selectedProjectId = project.id }
        }
    }
}

/// "No matches" / "No items" overlay for an empty table.
@ViewBuilder
private func emptyOverlay(_ isEmpty: Bool, all: Bool, noun: String) -> some View {
    if isEmpty {
        Text(all ? "No \(noun)." : "No matches.")
            .foregroundStyle(.secondary)
            .padding(.top, 30)
    }
}
