import AppKit
import DBEngineKit
import SwiftUI

/// Creates a local database service from Homebrew binaries or a folder.
struct NewDatabaseSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Pre-selected engine and port, e.g. when created from a project's `.env`.
    var initialKind: EngineKind = .postgresql
    var initialPort: Int?
    var initialName: String = ""

    private enum Source: Hashable {
        case installed(InstalledBinaries)
        case homebrew(String)
        case folder
    }

    @State private var kind: EngineKind = .postgresql
    @State private var installed: [InstalledBinaries] = []
    @State private var installable: [String] = []
    @State private var source: Source = .folder
    @State private var name = ""
    @State private var folder: URL?
    @State private var port = ""
    @State private var autoStart = true
    @State private var startNow = true
    @State private var progress = ""
    @State private var error: String?
    @State private var work: Task<Void, Never>?
    @State private var didAppear = false

    private var databases: DatabaseManager { appState.databaseManager }
    private var working: Bool { work != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Database").font(.title2.bold())

            if !databases.isHomebrewInstalled {
                NoticeBanner(
                    tone: .info,
                    message: "Homebrew isn't installed. Install it from brew.sh to get PostgreSQL, MySQL and Redis, or choose a folder with the server binaries."
                )
            }

            Form {
                Picker("Engine", selection: $kind) {
                    ForEach(EngineKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }

                Picker("Version", selection: $source) {
                    ForEach(installed) { binaries in
                        Text("\(binaries.version)  (Homebrew \(binaries.formula ?? ""))").tag(Source.installed(binaries))
                    }
                    if databases.isHomebrewInstalled {
                        ForEach(installable, id: \.self) { formula in
                            Text("Install \(formula) with Homebrew").tag(Source.homebrew(formula))
                        }
                    }
                    Divider()
                    Text("Choose a folder…").tag(Source.folder)
                }

                switch source {
                case .installed:
                    EmptyView()
                case .homebrew(let formula):
                    Text("Runs `brew install \(formula)` first. This can take a few minutes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .folder:
                    LabeledContent("Folder") {
                        HStack {
                            Text(folder?.path ?? "Folder that contains bin/\(kind.serverBinary)")
                                .foregroundStyle(folder == nil ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Choose…", action: chooseFolder)
                        }
                    }
                }

                TextField("Name", text: $name, prompt: Text(defaultName))
                TextField("Port", text: $port)
                Toggle("Start when Laradeck opens", isOn: $autoStart)
                Toggle("Start now", isOn: $startNow)
            }
            .formStyle(.grouped)
            .disabled(working)

            if let user = kind.defaultUser {
                Text("User \(user), empty password, listening on 127.0.0.1 only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text(progress)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
                Button("Cancel") {
                    work?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || !isValid)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            kind = initialKind
            name = initialName
            reload(port: initialPort)
        }
        .onChange(of: kind) { _, _ in
            guard didAppear else { return }
            reload(port: nil)
        }
    }

    private var effectiveVersion: String {
        switch source {
        case .installed(let binaries): return binaries.version
        case .homebrew(let formula): return formula.split(separator: "@").last.map(String.init) ?? formula
        case .folder: return folder?.lastPathComponent ?? ""
        }
    }

    private var defaultName: String {
        "\(kind.displayName) \(effectiveVersion)".trimmingCharacters(in: .whitespaces)
    }

    private var isValid: Bool {
        guard let port = Int(port), (1...65535).contains(port) else { return false }
        if case .folder = source { return folder != nil }
        return true
    }

    private func reload(port initialPort: Int?) {
        installed = databases.installedBinaries(for: kind)
        let have = Set(installed.compactMap(\.formula))
        installable = Homebrew.formulae(for: kind).filter { !have.contains($0) }
        if let first = installed.first {
            source = .installed(first)
        } else if databases.isHomebrewInstalled, let formula = installable.first {
            source = .homebrew(formula)
        } else {
            source = .folder
        }
        port = String(initialPort ?? databases.suggestedPort(for: kind))
        folder = nil
        error = nil
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the \(kind.displayName) folder that contains bin/\(kind.serverBinary)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard BinaryLocator.isValid(url, kind: kind) else {
            error = "\(url.path) has no bin/\(kind.serverBinary)"
            return
        }
        folder = url
        error = nil
    }

    private func create() {
        let binarySource: DatabaseManager.BinarySource
        switch source {
        case .installed(let binaries):
            // The formula path keeps the real version (opt/postgresql@17 -> 17.6).
            binarySource = binaries.formula.map { .homebrew($0) } ?? .folder(binaries.url)
        case .homebrew(let formula): binarySource = .homebrew(formula)
        case .folder:
            guard let folder else { return }
            binarySource = .folder(folder)
        }
        error = nil
        let kind = kind, port = Int(port)!, autoStart = autoStart, startNow = startNow
        let name = name.isEmpty ? defaultName : name
        work = Task {
            do {
                try await databases.create(kind: kind, name: name, source: binarySource, port: port,
                                           autoStart: autoStart, startNow: startNow) { text in
                    Task { @MainActor in progress = text }
                }
                work = nil
                dismiss()
            } catch is CancellationError {
                work = nil
            } catch {
                self.error = error.localizedDescription
                work = nil
            }
        }
    }
}
