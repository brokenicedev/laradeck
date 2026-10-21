import SwiftUI
import AppKit

/// Lets the developer override what auto-detection guessed — environment, logo, metadata, etc.
struct EditProjectView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private let project: Project

    @State private var name: String
    @State private var environment: ProjectEnvironment
    @State private var packageManager: PackageManager
    @State private var urlString: String
    @State private var tagsText: String
    @State private var autoStartOnLaunch: Bool
    @State private var iconStyle: ProjectIconStyle
    @State private var customIconPath: String?
    @State private var pendingIconPreviewPath: String?
    @State private var color: Color
    @State private var laravelVersion: String?
    @State private var phpVersion: String?
    @State private var isRefreshingMetadata = false
    @State private var iconImportError: String?
    @State private var teamConfigMessage: String?
    @State private var teamConfigError: String?

    init(project: Project) {
        self.project = project
        _name = State(initialValue: project.name)
        _environment = State(initialValue: project.environment)
        _packageManager = State(initialValue: project.packageManager)
        _urlString = State(initialValue: project.url ?? "")
        _tagsText = State(initialValue: project.tags.joined(separator: ", "))
        _autoStartOnLaunch = State(initialValue: project.autoStartOnLaunch)
        _iconStyle = State(initialValue: project.iconStyle ?? .initials)
        _customIconPath = State(initialValue: project.customIconPath)
        _color = State(initialValue: Color(hex: project.effectiveColorHex))
        _laravelVersion = State(initialValue: project.laravelVersion)
        _phpVersion = State(initialValue: project.phpVersion)
    }

    private var previewIconPath: String? {
        pendingIconPreviewPath ?? customIconPath
    }

    private var previewProject: Project {
        var preview = project
        preview.name = name
        preview.iconStyle = iconStyle
        preview.customIconPath = previewIconPath
        preview.colorHex = color.hexString
        return preview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    iconSection
                    identitySection
                    runtimeSection
                    teamConfigSection
                    metadataSection
                }
                .padding(24)
            }
            Divider()
            footer
                .padding(24)
        }
        .frame(width: 620, height: 720)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Edit Project")
                .font(.title.bold())
            PathLinkButton(path: project.path)
        }
        .padding(24)
    }

    private var iconSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Logo", systemImage: "photo")

            HStack(alignment: .top, spacing: 20) {
                ProjectFaviconView(
                    project: previewProject,
                    overrideIconPath: iconStyle == .customImage ? previewIconPath : nil,
                    size: 72
                )

                VStack(alignment: .leading, spacing: 12) {
                    Picker("Logo style", selection: $iconStyle) {
                        Text("Custom image").tag(ProjectIconStyle.customImage)
                        Text("Initials").tag(ProjectIconStyle.initials)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: iconStyle) { _, newStyle in
                        if newStyle == .initials {
                            pendingIconPreviewPath = nil
                        }
                    }

                    if iconStyle == .customImage {
                        HStack(spacing: 10) {
                            Button {
                                chooseCustomIcon()
                            } label: {
                                Label("Choose Image…", systemImage: "photo")
                            }
                            .buttonStyle(.laradeckOutline)
                            if previewIconPath != nil {
                                Button {
                                    removeCustomIcon()
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                                .buttonStyle(.laradeckOutline(accent: .red))
                            }
                        }
                        Text("PNG, JPEG, GIF, WebP, SVG, or ICO from your Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let iconImportError {
                            NoticeBanner(tone: .error, message: iconImportError)
                        }
                    }

                    ProjectColorSwatchPicker(color: $color)
                }
            }
            .padding(16)
            .laradeckCard(cornerRadius: 10)
        }
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Identity", systemImage: "character.textbox")
            Form {
                TextField("Name", text: $name)
                TextField("URL", text: $urlString, prompt: Text("http://project.test"))
                TextField("Tags", text: $tagsText, prompt: Text("Internal, Customer, Legacy…"))
            }
            .formStyle(.grouped)
        }
    }

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Runtime", systemImage: "terminal")

            Form {
                Picker("Environment", selection: $environment) {
                    Text("Native PHP").tag(ProjectEnvironment.native)
                    Text("Laravel Sail").tag(ProjectEnvironment.sail)
                }
                .pickerStyle(.segmented)

                if environment != project.environment {
                    Text(environmentChangeNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                MenuPicker(
                    "Package Manager",
                    selection: $packageManager,
                    options: PackageManager.allCases.map {
                        ($0, $0 == .none ? "None" : $0.executableName)
                    }
                )

                Toggle("Start automatically when Laradeck starts", isOn: $autoStartOnLaunch)
            }
            .formStyle(.grouped)
        }
    }

    private var teamConfigSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Team Config", systemImage: "person.2")

            VStack(alignment: .leading, spacing: 10) {
                Text("Write a `.laradeck` file in the project folder so teammates skip the add wizard. Safe to commit — it does not include `.env` secrets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    writeTeamConfig()
                } label: {
                    Label("Update .laradeck", systemImage: "doc.badge.gearshape")
                }
                .buttonStyle(.laradeckOutline)

                if LaradeckProfileStore.exists(at: project.path) {
                    Text("Found existing .laradeck in this folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let teamConfigMessage {
                    NoticeBanner(tone: .success, message: teamConfigMessage)
                }
                if let teamConfigError {
                    NoticeBanner(tone: .error, message: teamConfigError)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .laradeckCard(cornerRadius: 10)
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Detected Info", systemImage: "info.circle")

            Form {
                if let laravelVersion {
                    LabeledContent {
                        Text(laravelVersion)
                    } label: {
                        HStack(spacing: 6) {
                            LaravelLogoView(size: 14)
                            Text("Laravel")
                        }
                    }
                }
                if let phpVersion {
                    LabeledContent("PHP", value: phpVersion)
                }
                if laravelVersion == nil && phpVersion == nil && !isRefreshingMetadata {
                    Text("Not detected yet — refresh to probe the project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await refreshMetadata() }
                } label: {
                    if isRefreshingMetadata {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh Info", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.laradeckOutline)
                .disabled(isRefreshingMetadata)
            }
            .formStyle(.grouped)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
            Spacer()
            Button {
                save()
            } label: {
                Label("Save", systemImage: "checkmark")
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(name.isEmpty)
        }
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
    }

    private var environmentChangeNote: String {
        let destination = environment == .sail ? "Sail" : "native PHP"
        return "Web Server, Queue Worker, Scheduler, Horizon and Reverb will be switched to run through \(destination) when you save. Custom processes and Vite are left untouched."
    }

    private func chooseCustomIcon() {
        iconImportError = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ProjectIconStore.openPanelTypes
        panel.message = "Choose a logo for this project"
        panel.prompt = "Choose"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let importedPath = try ProjectIconStore.importIcon(from: url, projectId: project.id)
            customIconPath = importedPath
            pendingIconPreviewPath = importedPath
            iconStyle = .customImage
        } catch {
            iconImportError = error.localizedDescription
        }
    }

    private func removeCustomIcon() {
        ProjectIconStore.removeIcon(for: project.id)
        customIconPath = nil
        pendingIconPreviewPath = nil
        iconStyle = .initials
        iconImportError = nil
    }

    private func refreshMetadata() async {
        isRefreshingMetadata = true
        defer { isRefreshingMetadata = false }
        await appState.refreshMetadata(for: project)
        if let updated = appState.project(withId: project.id) {
            laravelVersion = updated.laravelVersion
            phpVersion = updated.phpVersion
        }
    }

    private func save() {
        var updated = project
        updated.name = name
        updated.packageManager = packageManager
        updated.url = urlString.isEmpty ? nil : urlString
        updated.tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        updated.autoStartOnLaunch = autoStartOnLaunch
        updated.iconStyle = iconStyle
        updated.customIconPath = iconStyle == .customImage ? customIconPath : nil
        updated.colorHex = color.hexString
        updated.laravelVersion = laravelVersion
        updated.phpVersion = phpVersion

        if iconStyle != .customImage {
            ProjectIconStore.removeIcon(for: project.id)
            updated.customIconPath = nil
        }

        if environment != project.environment {
            updated.environment = environment
            updated.processes = ProcessDefinitionFactory.adaptExecutables(updated.processes, to: environment)
        }

        appState.updateProject(updated)
        dismiss()
    }

    private func writeTeamConfig() {
        teamConfigMessage = nil
        teamConfigError = nil
        var snapshot = project
        snapshot.name = name
        snapshot.packageManager = packageManager
        snapshot.url = urlString.isEmpty ? nil : urlString
        snapshot.tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        snapshot.autoStartOnLaunch = autoStartOnLaunch
        snapshot.iconStyle = iconStyle == .customImage ? .initials : iconStyle
        snapshot.colorHex = color.hexString
        snapshot.environment = environment
        if environment != project.environment {
            snapshot.processes = ProcessDefinitionFactory.adaptExecutables(snapshot.processes, to: environment)
        }
        do {
            try LaradeckProfileStore.write(from: snapshot)
            teamConfigMessage = "Updated .laradeck in the project folder."
        } catch {
            teamConfigError = error.localizedDescription
        }
    }
}
