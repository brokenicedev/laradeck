import SwiftUI
import AppKit

/// Runs once per project being added — basics, Laravel core processes, then optional scripts
/// from package.json / composer.json (with an "Other commands" group excluded from Start All).
struct ProjectWizardView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let path: String
    var onAdded: () -> Void = {}

    private enum StepKind: Hashable {
        case basics
        case coreProcesses
        case artisanCommands
        case scripts
    }

    @State private var stepIndex = 0

    @State private var name: String
    @State private var environment: ProjectEnvironment
    @State private var packageManager: PackageManager
    @State private var draftProjectId: UUID
    @State private var iconStyle: ProjectIconStyle = .initials
    @State private var customIconPath: String?
    @State private var pendingIconPreviewPath: String?
    @State private var color: Color
    @State private var iconImportError: String?
    @State private var coreProcesses: [ProcessDefinition]
    @State private var includedCoreIds: Set<UUID>
    @State private var artisanOptions: [WizardArtisanOption] = []
    @State private var isLoadingArtisan = false
    @State private var scriptOptions: [WizardScriptOption]
    @State private var saveTeamConfig: Bool

    private let metadata: LaravelMetadata
    private let isLaravel: Bool

    init(path: String, onAdded: @escaping () -> Void = {}) {
        self.path = path
        self.onAdded = onAdded

        let isLaravel = LaravelDetector.isLaravelProject(at: path)
        self.isLaravel = isLaravel
        let detectedEnvironment: ProjectEnvironment = isLaravel && SailDetector.usesSail(at: path) ? .sail : .native
        let detectedPackageManager = PackageManagerDetector.detect(at: path)
        let detectedMetadata = LaravelDetector.detectMetadata(at: path)
        let proposed = ProcessDefinitionFactory.proposedProcesses(
            environment: detectedEnvironment,
            packageManager: detectedPackageManager,
            metadata: detectedMetadata,
            isLaravel: isLaravel,
            includePackageScripts: false
        )
        let scripts = ScriptCommandDiscovery.discover(
            at: path,
            environment: detectedEnvironment,
            packageManager: detectedPackageManager,
            importScope: .devAndWatchOnly
        )

        self.metadata = detectedMetadata
        let defaultName = (path as NSString).lastPathComponent
        _name = State(initialValue: defaultName)
        _draftProjectId = State(initialValue: UUID())
        _color = State(initialValue: Color(hex: ProjectColorPalette.defaultHex(for: defaultName)))
        _environment = State(initialValue: detectedEnvironment)
        _packageManager = State(initialValue: detectedPackageManager)
        _coreProcesses = State(initialValue: proposed)
        _includedCoreIds = State(initialValue: Set(proposed.map(\.id)))
        _scriptOptions = State(initialValue: scripts)
        _saveTeamConfig = State(initialValue: LaradeckProfileStore.looksLikeGitRepo(at: path))
    }

    private var hasPackageJson: Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("package.json"))
    }

    private var activeSteps: [StepKind] {
        var steps: [StepKind] = [.basics]
        if isLaravel, !coreProcesses.isEmpty { steps.append(.coreProcesses) }
        if isLaravel { steps.append(.artisanCommands) }
        if !scriptOptions.isEmpty { steps.append(.scripts) }
        return steps
    }

    private var currentStep: StepKind {
        activeSteps[min(stepIndex, activeSteps.count - 1)]
    }

    private var isLastStep: Bool {
        stepIndex >= activeSteps.count - 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            wizardHeader
            progressBar
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

            Divider()

            Group {
                switch currentStep {
                case .basics: basicsStep
                case .coreProcesses: coreProcessesStep
                case .artisanCommands: artisanCommandsStep
                case .scripts: scriptsStep
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            footer
                .padding(20)
        }
        .frame(width: 580, height: 660)
        .task(id: "\(path)|\(environment.rawValue)") {
            // Discovery shells out via a login zsh — keep it off the UI thread so drop/open doesn't freeze.
            await loadArtisanCommands()
        }
    }

    // MARK: - Chrome

    private var wizardHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: headerIcon)
                .font(.system(size: 22))
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(headerTitle)
                    .font(.title2.bold())
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text("Step \(stepIndex + 1) of \(activeSteps.count)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5), in: Capsule())
        }
        .padding(20)
    }

    private var headerIcon: String {
        switch currentStep {
        case .basics: return "folder.badge.plus"
        case .coreProcesses: return "shippingbox"
        case .artisanCommands: return "terminal"
        case .scripts: return "curlybraces"
        }
    }

    private var headerTitle: String {
        switch currentStep {
        case .basics: return "New Project"
        case .coreProcesses: return "Laravel Processes"
        case .artisanCommands: return "Artisan Commands"
        case .scripts: return "Scripts & Commands"
        }
    }

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(Array(activeSteps.enumerated()), id: \.offset) { index, _ in
                Capsule()
                    .fill(index <= stepIndex ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(height: 4)
            }
        }
    }

    // MARK: - Steps

    private var basicsStep: some View {
        Form {
            if !isLaravel {
                Section {
                    Label {
                        Text("Laravel wasn't detected. You can still add this folder and configure commands manually.")
                            .font(.callout)
                    } icon: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Project") {
                TextField("Name", text: $name)

                if isLaravel {
                    Picker("Environment", selection: $environment) {
                        Text("Native PHP").tag(ProjectEnvironment.native)
                        Text("Laravel Sail").tag(ProjectEnvironment.sail)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: environment) { _, _ in refreshAfterEnvironmentChange() }
                }

                if hasPackageJson {
                    packageManagerSection
                }
            }

            Section {
                ProjectAppearanceSection(
                    previewProject: appearancePreviewProject,
                    overrideIconPath: iconStyle == .customImage ? previewIconPath : nil,
                    iconStyle: $iconStyle,
                    color: $color,
                    iconImportError: iconImportError,
                    onChooseImage: chooseCustomIcon,
                    onRemoveImage: removeCustomIcon
                )
            }

            if metadata.hasHorizon || metadata.hasReverb {
                Section("Detected") {
                    if metadata.hasHorizon {
                        LabeledContent("Queue", value: "Horizon")
                    }
                    if metadata.hasReverb {
                        LabeledContent("WebSockets", value: "Reverb")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var coreProcessesStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("These start with Start All — the core Laravel dev stack.")
                .font(.callout)
                .foregroundStyle(.secondary)

            coreProcessList
        }
    }

    private var artisanCommandsStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Extra artisan commands from your app and installed packages. Most belong in Other commands — one-click shortcuts, not part of Start All.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if isLoadingArtisan {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning artisan list…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else if artisanOptions.isEmpty {
                Text("No additional artisan commands found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach($artisanOptions) { $option in
                            artisanRow($option)
                            if option.id != artisanOptions.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .laradeckCard(cornerRadius: 10)
            }
        }
    }

    private var scriptsStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Optional dev and watch scripts from package.json and composer.json. Pre-selected scripts go to Other commands — not Start All.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach($scriptOptions) { $option in
                        scriptRow($option)
                        if option.id != scriptOptions.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .laradeckCard(cornerRadius: 10)
        }
    }

    private var packageManagerDetection: PackageManagerDetection {
        PackageManagerDetector.detectDetailed(at: path)
    }

    @ViewBuilder
    private var packageManagerSection: some View {
        if packageManagerDetection.isConfident {
            LabeledContent("Frontend tool", value: packageManagerDetection.label)
            Text(packageManagerDetection.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            MenuPicker(
                "Frontend tool",
                selection: $packageManager,
                options: PackageManager.allCases.filter { $0 != .none }.map {
                    ($0, $0.executableName)
                }
            )
            .onChange(of: packageManager) { _, _ in refreshAfterEnvironmentChange() }

            Text(packageManagerDetection.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var coreProcessList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach($coreProcesses) { $definition in
                    coreProcessRow($definition)
                    if definition.id != coreProcesses.last?.id {
                        Divider()
                    }
                }
                if coreProcesses.isEmpty {
                    Text("Nothing proposed — add custom processes from the dashboard.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
        }
        .laradeckCard(cornerRadius: 10)
    }

    private func coreProcessRow(_ definition: Binding<ProcessDefinition>) -> some View {
        let isIncluded = includedCoreIds.contains(definition.wrappedValue.id)

        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { includedCoreIds.contains(definition.wrappedValue.id) },
                set: { isOn in
                    if isOn {
                        includedCoreIds.insert(definition.wrappedValue.id)
                    } else {
                        includedCoreIds.remove(definition.wrappedValue.id)
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            Image(systemName: definition.wrappedValue.kind.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(definition.wrappedValue.name)
                    .font(.body.weight(.medium))
                Text(definition.wrappedValue.commandLine)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            MenuPicker(
                selection: definition.type,
                width: 130,
                options: [
                    (.longRunning, "Long Running"),
                    (.oneShot, "One Shot"),
                    (.shortcut, "Shortcut"),
                ]
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .opacity(isIncluded ? 1 : 0.45)
        .disabled(!isIncluded)
    }

    private func artisanRow(_ option: Binding<WizardArtisanOption>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: option.isIncluded)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(option.wrappedValue.name)
                        .font(.body.weight(.medium).monospaced())
                    Text("artisan")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }
                if !option.wrappedValue.description.isEmpty {
                    Text(option.wrappedValue.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(option.wrappedValue.commandPreview)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if option.wrappedValue.isIncluded {
                MenuPicker(
                    selection: Binding(
                        get: { option.wrappedValue.useOtherCommandsGroup },
                        set: { option.wrappedValue.useOtherCommandsGroup = $0 }
                    ),
                    width: 150,
                    options: [
                        (false, "Start All"),
                        (true, "Other commands"),
                    ]
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .opacity(option.wrappedValue.isIncluded ? 1 : 0.5)
    }

    private func scriptRow(_ option: Binding<WizardScriptOption>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: option.isIncluded)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(option.wrappedValue.name)
                        .font(.body.weight(.medium))
                    Text(option.wrappedValue.sourceLabel)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }
                Text(option.wrappedValue.commandPreview)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if option.wrappedValue.isIncluded {
                if option.wrappedValue.useOtherCommandsGroup {
                    Text("Other commands")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 150, alignment: .trailing)
                } else {
                    MenuPicker(
                        selection: Binding(
                            get: { option.wrappedValue.useOtherCommandsGroup },
                            set: { option.wrappedValue.useOtherCommandsGroup = $0 }
                        ),
                        width: 150,
                        options: [
                            (false, "Start All"),
                            (true, "Other commands"),
                        ]
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .opacity(option.wrappedValue.isIncluded ? 1 : 0.5)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isLastStep {
                Toggle("Save team config (.laradeck)", isOn: $saveTeamConfig)
                Text("Writes a portable project setup next to the code so teammates skip this wizard. Does not include .env secrets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                if stepIndex > 0 {
                    Button("Back") { stepIndex -= 1 }
                }
                if isLastStep {
                    Button("Add Project") { addProject() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Next") { stepIndex += 1 }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(currentStep == .basics && name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    // MARK: - Actions

    private func refreshAfterEnvironmentChange() {
        coreProcesses = ProcessDefinitionFactory.proposedProcesses(
            environment: environment,
            packageManager: packageManager,
            metadata: metadata,
            isLaravel: isLaravel,
            includePackageScripts: false
        )
        includedCoreIds = Set(coreProcesses.map(\.id))
        scriptOptions = ScriptCommandDiscovery.discover(
            at: path,
            environment: environment,
            packageManager: packageManager,
            importScope: .devAndWatchOnly
        )
    }

    private var appearancePreviewProject: Project {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        var preview = Project(
            id: draftProjectId,
            name: trimmedName.isEmpty ? (path as NSString).lastPathComponent : trimmedName,
            path: path,
            environment: environment,
            packageManager: packageManager
        )
        preview.iconStyle = iconStyle
        preview.customIconPath = previewIconPath
        preview.colorHex = color.hexString
        return preview
    }

    private var previewIconPath: String? {
        pendingIconPreviewPath ?? customIconPath
    }

    private func chooseCustomIcon() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ProjectIconStore.openPanelTypes
        panel.message = "Choose a logo for this project"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let storedPath = try ProjectIconStore.importIcon(from: url, projectId: draftProjectId)
            customIconPath = storedPath
            pendingIconPreviewPath = storedPath
            iconStyle = .customImage
            iconImportError = nil
        } catch {
            iconImportError = error.localizedDescription
        }
    }

    private func removeCustomIcon() {
        ProjectIconStore.removeIcon(for: draftProjectId)
        customIconPath = nil
        pendingIconPreviewPath = nil
        iconStyle = .initials
        iconImportError = nil
    }

    private func loadArtisanCommands() async {
        guard isLaravel else {
            artisanOptions = []
            return
        }
        isLoadingArtisan = true
        defer { isLoadingArtisan = false }
        artisanOptions = await ArtisanCommandDiscovery.discover(at: path, environment: environment)
    }

    private func addProject() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        var project = Project(
            id: draftProjectId,
            name: trimmedName.isEmpty ? (path as NSString).lastPathComponent : trimmedName,
            path: path,
            environment: environment,
            packageManager: packageManager
        )
        project.url = metadata.appURL
        project.hasHorizon = metadata.hasHorizon
        project.hasReverb = metadata.hasReverb
        project.iconStyle = iconStyle
        project.colorHex = color.hexString
        project.customIconPath = iconStyle == .customImage ? customIconPath : nil
        project.ensureOtherCommandsGroup()
        let otherGroupId = project.otherCommandsGroupId

        var allProcesses = coreProcesses.filter { includedCoreIds.contains($0.id) }

        for option in artisanOptions where option.isIncluded {
            var definition = ArtisanCommandDiscovery.makeProcessDefinition(
                from: option,
                environment: environment,
                projectPath: path
            )
            if option.useOtherCommandsGroup, let otherGroupId {
                definition.groupId = otherGroupId
            }
            allProcesses.append(definition)
        }

        for option in scriptOptions where option.isIncluded {
            var definition = ScriptCommandDiscovery.makeProcessDefinition(
                from: option,
                environment: environment,
                packageManager: packageManager
            )
            if option.useOtherCommandsGroup, let otherGroupId {
                definition.groupId = otherGroupId
            }
            allProcesses.append(definition)
        }

        project.processes = allProcesses

        appState.addProject(project)
        if saveTeamConfig {
            try? LaradeckProfileStore.write(from: project)
        }
        onAdded()
        dismiss()
    }
}
