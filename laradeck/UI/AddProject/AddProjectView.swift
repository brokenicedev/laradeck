import SwiftUI
import AppKit

/// Scans a folder for Laravel projects, then adds them one at a time — each pick opens
/// `ProjectWizardView` rather than bulk-importing with silently auto-guessed settings.
struct AddProjectView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var rootPath: String
    @State private var isScanning = false
    @State private var hasScanned = false
    @State private var discovered: [DiscoveredProject] = []
    @State private var wizardPath: String?
    @State private var importNotice: String?

    private let autoScanOnAppear: Bool

    init(initialPath: String? = nil) {
        _rootPath = State(initialValue: initialPath ?? (("~/Development") as NSString).expandingTildeInPath)
        autoScanOnAppear = initialPath != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scan for Laravel Projects")
                .font(.title2.bold())

            HStack {
                TextField("Folder to scan", text: $rootPath)
                Button {
                    chooseFolder()
                } label: {
                    Label("Choose…", systemImage: "folder")
                }
                .buttonStyle(.laradeckOutline)
            }

            Group {
                if isScanning {
                    ProgressView("Scanning \(rootPath)…")
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else if hasScanned {
                    if discovered.isEmpty {
                        VStack(spacing: 16) {
                            ContentUnavailableView(
                                "No Laravel Projects Found",
                                systemImage: "magnifyingglass",
                                description: Text("Add this folder anyway and configure custom commands from the dashboard.")
                            )
                            Button("Add \"\(scannedFolderName)\" Anyway") {
                                openProjectPath(expandedRootPath)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Found \(discovered.count) Laravel project\(discovered.count == 1 ? "" : "s") — pick one to add")
                                .foregroundStyle(.secondary)
                            List(discovered) { project in
                                resultRow(project)
                            }
                            .frame(minHeight: 220)
                        }
                    }
                } else {
                    ContentUnavailableView("Choose a folder and scan", systemImage: "folder")
                        .frame(minHeight: 220)
                }
            }

            HStack {
                Button("Done") { dismiss() }
                Button {
                    chooseFolderForWizard()
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
                .buttonStyle(.laradeckOutline)
                Spacer()
                Button {
                    Task { await scan() }
                } label: {
                    Label("Scan", systemImage: "magnifyingglass")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(rootPath.isEmpty || isScanning)
            }
        }
        .padding(20)
        .frame(width: 520, height: 480)
        .task {
            if autoScanOnAppear, !rootPath.isEmpty {
                await scan()
            }
        }
        .sheet(item: wizardTargetBinding) { target in
            ProjectWizardView(path: target.path) {
                markAdded(target.path)
                dismiss()
            }
        }
        .alert("Team config", isPresented: Binding(
            get: { importNotice != nil },
            set: { if !$0 { importNotice = nil } }
        )) {
            Button("OK") { importNotice = nil }
        } message: {
            if let importNotice {
                Text(importNotice)
            }
        }
    }

    private var expandedRootPath: String {
        (rootPath as NSString).expandingTildeInPath
    }

    private var scannedFolderName: String {
        (expandedRootPath as NSString).lastPathComponent
    }

    private var wizardTargetBinding: Binding<WizardTarget?> {
        Binding(
            get: { wizardPath.map(WizardTarget.init) },
            set: { wizardPath = $0?.path }
        )
    }

    private func resultRow(_ project: DiscoveredProject) -> some View {
        HStack(spacing: 10) {
            LaravelLogoView(size: 22)
            VStack(alignment: .leading) {
                Text(project.name)
                Text(project.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if project.alreadyAdded {
                Text("Already added")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .opacity(project.alreadyAdded ? 0.5 : 1)
        .onTapGesture {
            guard !project.alreadyAdded else { return }
            openProjectPath(project.path)
        }
    }

    private func openProjectPath(_ path: String) {
        switch LaradeckProjectImporter.tryImport(at: path, into: appState) {
        case .imported:
            markAdded(path)
            dismiss()
        case .alreadyAdded:
            markAdded(path)
            if let existing = appState.projects.first(where: { $0.path == path }) {
                appState.selectedProjectId = existing.id
            }
            dismiss()
        case .failed(let message):
            importNotice = "Could not read .laradeck: \(message). Opening the wizard…"
            wizardPath = path
        case .noProfile:
            wizardPath = path
        }
    }

    private func markAdded(_ path: String) {
        guard let index = discovered.firstIndex(where: { $0.path == path }) else { return }
        discovered[index].alreadyAdded = true
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            rootPath = url.path
        }
    }

    /// Skips Laravel scan — opens the wizard directly for manual process setup.
    private func chooseFolderForWizard() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        if panel.runModal() == .OK, let url = panel.url {
            openProjectPath(url.path)
        }
    }

    private func scan() async {
        isScanning = true
        defer { isScanning = false }
        discovered = await appState.scanForProjects(rootPaths: [rootPath])
        hasScanned = true
    }
}

private struct WizardTarget: Identifiable {
    let path: String
    var id: String { path }
}
