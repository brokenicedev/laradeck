import SwiftUI
import AppKit

/// Where a process being added/edited ends up — the built-in "Processes" list, a user-created
/// group, or one of the two lifecycle-hook sections.
enum ProcessDestination: Hashable, Identifiable {
    var id: Self { self }

    case processes
    case preStart
    case postStart
    case postStop
    case group(UUID)

    static func from(groupId: UUID?, role: ProcessRole) -> ProcessDestination {
        switch role {
        case .preStart: return .preStart
        case .postStart: return .postStart
        case .postStop: return .postStop
        case .normal: return groupId.map(ProcessDestination.group) ?? .processes
        }
    }

    var groupId: UUID? {
        if case .group(let id) = self { return id }
        return nil
    }

    var role: ProcessRole {
        switch self {
        case .preStart: return .preStart
        case .postStart: return .postStart
        case .postStop: return .postStop
        case .processes, .group: return .normal
        }
    }
}

/// Also used to edit an existing process — pass `editing:` to pre-fill the form and update the
/// definition in place on save instead of appending a new one.
struct CustomProcessSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let editingDefinitionId: UUID?
    /// Section the sheet was opened from — preserved when picking a command.
    private let initialDestination: ProcessDestination

    private enum Step {
        case pick
        case configure
    }

    private static let customPickID = "custom"

    @State private var step: Step
    @State private var selectedPickId: String?
    @State private var showingPresetManager = false

    @State private var name = ""
    @State private var executable = ""
    @State private var argumentsText = ""
    @State private var workingDirectory = ""
    @State private var environmentText = ""
    @State private var type: ProcessExecutionType = .longRunning
    @State private var autoStart = false
    @State private var isInteractiveCommand = false
    @State private var restartPolicy: RestartPolicy = .never
    @State private var watchPathsText = ""
    @State private var watchDebounceMs = 500
    @State private var scriptOptions: [WizardScriptOption] = []
    @State private var artisanOptions: [WizardArtisanOption] = []
    @State private var isLoadingDiscoveredCommands = false
    @State private var pickSearchText = ""
    @State private var expandedPickSections: Set<String> = []

    private static let folderWatchPickID = "folder-watch"

    private var isFolderWatch: Bool { type == .folderWatch }

    private var supportsInteractiveCommand: Bool {
        type == .longRunning || type == .oneShot
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if isFolderWatch {
            return !parsedWatchPaths.isEmpty
        }
        return !executable.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var parsedWatchPaths: [String] {
        watchPathsText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    @State private var groups: [ProcessGroup]
    @State private var destination: ProcessDestination
    @State private var isCreatingGroup = false
    @State private var newGroupName = ""

    private var isEditing: Bool { editingDefinitionId != nil }

    private var npmScripts: [WizardScriptOption] {
        scriptOptions.filter { $0.source == .npm }
    }

    private var composerScripts: [WizardScriptOption] {
        scriptOptions.filter { $0.source == .composer }
    }

    private func matchesSearch(_ fields: [String]) -> Bool {
        guard !pickSearchText.isEmpty else { return true }
        return fields.contains { $0.localizedCaseInsensitiveContains(pickSearchText) }
    }

    private var filteredNpmScripts: [WizardScriptOption] {
        npmScripts.filter { matchesSearch([$0.name, $0.commandPreview]) }
    }

    private var filteredComposerScripts: [WizardScriptOption] {
        composerScripts.filter { matchesSearch([$0.name, $0.commandPreview]) }
    }

    private var filteredArtisanOptions: [WizardArtisanOption] {
        artisanOptions.filter { matchesSearch([$0.name, $0.commandPreview, $0.description]) }
    }

    private var filteredPresetPickItems: [PresetPickItem] {
        presetPickItems.filter { matchesSearch([$0.presetName, $0.command]) }
    }

    /// Collapsed sections auto-expand while a search is active and they contain a match.
    private func expandedBinding(_ key: String, hasMatches: Bool) -> Binding<Bool> {
        Binding(
            get: { expandedPickSections.contains(key) || (!pickSearchText.isEmpty && hasMatches) },
            set: { isExpanded in
                if isExpanded {
                    expandedPickSections.insert(key)
                } else {
                    expandedPickSections.remove(key)
                }
            }
        )
    }

    private var showPickStep: Bool {
        !isEditing
    }

    private var activeSteps: [Step] {
        showPickStep ? [.pick, .configure] : [.configure]
    }

    private var stepIndex: Int {
        activeSteps.firstIndex(of: step) ?? 0
    }

    private var presetPickItems: [PresetPickItem] {
        appState.presets.flatMap { preset in
            preset.commands.enumerated().map { index, command in
                PresetPickItem(
                    id: Self.presetPickID(presetId: preset.id, commandIndex: index),
                    presetName: preset.name,
                    command: command
                )
            }
        }
    }

    private struct PresetPickItem: Identifiable {
        let id: String
        let presetName: String
        let command: String
    }

    private var destinationOptions: [(ProcessDestination, String)] {
        var options: [(ProcessDestination, String)] = [
            (.processes, "Processes"),
            (.preStart, "Pre-start"),
            (.postStart, "Post-start"),
            (.postStop, "Post-stop"),
        ]
        for group in groups {
            options.append((.group(group.id), group.name))
        }
        return options
    }

    init(project: Project, initialDestination: ProcessDestination = .processes) {
        self.project = project
        self.editingDefinitionId = nil
        self.initialDestination = initialDestination
        var prepared = project
        prepared.ensureOtherCommandsGroup()
        _groups = State(initialValue: prepared.effectiveProcessGroups)
        _destination = State(initialValue: initialDestination)
        _step = State(initialValue: .pick)
    }

    init(project: Project, editing definition: ProcessDefinition) {
        self.project = project
        self.editingDefinitionId = definition.id
        let destination = ProcessDestination.from(groupId: definition.groupId, role: definition.effectiveRole)
        self.initialDestination = destination
        var prepared = project
        prepared.ensureOtherCommandsGroup()
        _groups = State(initialValue: prepared.effectiveProcessGroups)
        _destination = State(initialValue: destination)
        _step = State(initialValue: .configure)
        _name = State(initialValue: definition.name)
        _executable = State(initialValue: definition.executable)
        _argumentsText = State(initialValue: definition.arguments.joined(separator: " "))
        _workingDirectory = State(initialValue: definition.workingDirectory ?? "")
        _environmentText = State(initialValue: definition.environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n"))
        _type = State(initialValue: definition.type)
        _autoStart = State(initialValue: definition.autoStart)
        _isInteractiveCommand = State(initialValue: definition.isInteractiveCommand)
        _restartPolicy = State(initialValue: definition.restartPolicy)
        _watchPathsText = State(initialValue: definition.watchPaths.joined(separator: "\n"))
        _watchDebounceMs = State(initialValue: definition.watchDebounceMs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader
            if showPickStep {
                progressBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
            }

            Divider()

            Group {
                switch step {
                case .pick: pickStep
                case .configure: configureStep
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            footer
                .padding(20)
        }
        .frame(width: 580, height: step == .pick ? 560 : 640)
        .task(id: project.id) {
            var updated = project
            updated.ensureOtherCommandsGroup()
            if updated.effectiveProcessGroups.count != project.effectiveProcessGroups.count {
                appState.updateProject(updated)
                groups = updated.effectiveProcessGroups
            }
            await loadDiscoveredCommands()
        }
        .sheet(isPresented: $showingPresetManager) {
            CommandPresetsManagerView()
        }
    }

    // MARK: - Chrome

    private var sheetHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: headerIcon)
                .font(.system(size: 20))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(headerTitle)
                    .font(.title2.bold())
                Text(project.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if showPickStep {
                Text("Step \(stepIndex + 1) of \(activeSteps.count)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5), in: Capsule())
            }
        }
        .padding(20)
    }

    private var headerIcon: String {
        switch step {
        case .pick: return "list.bullet.rectangle"
        case .configure: return isEditing ? "pencil" : "plus.rectangle.on.rectangle"
        }
    }

    private var headerTitle: String {
        switch step {
        case .pick: return "Choose Command"
        case .configure: return isEditing ? "Edit Process" : "Configure Process"
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

    private var pickStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick a package.json, composer.json, artisan, or preset command — or write a custom one.")
                .font(.callout)
                .foregroundStyle(.secondary)

            pickSearchField

            ScrollView {
                VStack(spacing: 0) {
                    pickSectionHeader("Manual")
                    DiscoveredCommandRow(
                        name: "Custom command",
                        sourceBadge: "manual",
                        commandPreview: "Define your own executable and arguments",
                        isSelected: selectedPickId == Self.customPickID
                    ) {
                        selectedPickId = Self.customPickID
                    }
                    DiscoveredCommandRow(
                        name: "Folder watch",
                        sourceBadge: "watch",
                        commandPreview: "Watch folders and run nested processes on change",
                        isSelected: selectedPickId == Self.folderWatchPickID
                    ) {
                        selectedPickId = Self.folderWatchPickID
                    }

                    if !npmScripts.isEmpty {
                        pickDisclosureSection(
                            "package.json",
                            key: "npm",
                            count: filteredNpmScripts.count,
                            hasMatches: !filteredNpmScripts.isEmpty
                        ) {
                            ForEach(filteredNpmScripts) { option in
                                scriptPickRow(option)
                                if option.id != filteredNpmScripts.last?.id {
                                    Divider().padding(.leading, 36)
                                }
                            }
                        }
                    }

                    if !composerScripts.isEmpty {
                        pickDisclosureSection(
                            "composer.json",
                            key: "composer",
                            count: filteredComposerScripts.count,
                            hasMatches: !filteredComposerScripts.isEmpty
                        ) {
                            ForEach(filteredComposerScripts) { option in
                                scriptPickRow(option)
                                if option.id != filteredComposerScripts.last?.id {
                                    Divider().padding(.leading, 36)
                                }
                            }
                        }
                    }

                    if !artisanOptions.isEmpty || isLoadingDiscoveredCommands {
                        pickDisclosureSection(
                            "Artisan",
                            key: "artisan",
                            count: filteredArtisanOptions.count,
                            isLoading: isLoadingDiscoveredCommands,
                            hasMatches: !filteredArtisanOptions.isEmpty
                        ) {
                            ForEach(filteredArtisanOptions) { option in
                                artisanPickRow(option)
                                if option.id != filteredArtisanOptions.last?.id {
                                    Divider().padding(.leading, 36)
                                }
                            }
                        }
                    }

                    pickDisclosureSection(
                        "Presets",
                        key: "presets",
                        count: filteredPresetPickItems.count,
                        hasMatches: !filteredPresetPickItems.isEmpty
                    ) {
                        if appState.presets.isEmpty {
                            Text("No presets yet — create reusable command bundles.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(filteredPresetPickItems) { item in
                                presetPickRow(item)
                                if item.id != filteredPresetPickItems.last?.id {
                                    Divider().padding(.leading, 36)
                                }
                            }
                        }
                        Button("Manage Presets…") {
                            showingPresetManager = true
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .laradeckCard(cornerRadius: 10)
        }
    }

    private var pickSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search commands", text: $pickSearchText)
                .textFieldStyle(.plain)
            if !pickSearchText.isEmpty {
                Button {
                    pickSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    /// A collapsible pick section — collapsed by default, auto-expands while a search matches it.
    @ViewBuilder
    private func pickDisclosureSection<Content: View>(
        _ title: String,
        key: String,
        count: Int,
        isLoading: Bool = false,
        hasMatches: Bool,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup(isExpanded: expandedBinding(key, hasMatches: hasMatches)) {
            VStack(spacing: 0) {
                content()
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("\(count)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var configureStep: some View {
        ScrollView {
            Form {
                if let badge = selectedSourceBadge {
                    Section {
                        Label {
                            Text("Based on \(badge)")
                                .font(.callout)
                        } icon: {
                            Image(systemName: "wand.and.stars")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Command") {
                    TextField("Name", text: $name)
                    if isFolderWatch {
                        Text("Watch paths (one per line)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $watchPathsText)
                            .font(.system(size: 12, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .frame(height: 72)
                            .overlay {
                                if watchPathsText.isEmpty {
                                    Text("public/build/manifest.json\nvendor/brokenice/nitrogen/dist")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                        .allowsHitTesting(false)
                                }
                            }
                        Text("Files or folders — relative to the project root, or absolute. Prefer a single file (e.g. manifest.json): Laradeck waits until that file stops changing before running nested children, which avoids Vite’s double-write. Nested children run after the debounce settles.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Stepper(value: $watchDebounceMs, in: 0...10_000, step: 100) {
                            Text("Debounce \(watchDebounceMs) ms")
                        }
                    } else {
                        TextField("Executable", text: $executable, prompt: Text("php, npm, sail…"))
                        TextField("Arguments", text: $argumentsText, prompt: Text("artisan queue:work"))
                        HStack {
                            TextField("Working Directory", text: $workingDirectory, prompt: Text(project.path))
                            Button("Choose…") { chooseWorkingDirectory() }
                        }
                    }
                }

                if !isFolderWatch {
                    Section("Environment") {
                        TextEditor(text: $environmentText)
                            .font(.system(size: 12, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .frame(height: 56)
                            .overlay {
                                if environmentText.isEmpty {
                                    Text("PHP_CLI_SERVER_WORKERS=4")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                        .allowsHitTesting(false)
                                }
                            }
                        Text("One KEY=VALUE per line.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Behavior") {
                    MenuPicker(
                        "Type",
                        selection: $type,
                        options: [
                            (.longRunning, "Long Running"),
                            (.oneShot, "One Shot"),
                            (.shortcut, "Shortcut"),
                            (.folderWatch, "Folder Watch"),
                        ]
                    )
                    if !isFolderWatch {
                        MenuPicker(
                            "Restart Policy",
                            selection: $restartPolicy,
                            options: [
                                (.never, "Never"),
                                (.onFailure, "On Failure"),
                                (.always, "Always"),
                            ]
                        )
                    }
                    Toggle("Auto Start on Laradeck Launch", isOn: $autoStart)
                        .help("Starts this process when Laradeck itself launches — requires the project's own \"Start automatically when Laradeck starts\" setting (Edit Project). Unrelated to Start All; use the group's Start All toggle for that.")
                    if supportsInteractiveCommand {
                        Toggle("Interactive Command", isOn: $isInteractiveCommand)
                            .help("Opens Logs on play and lets you answer prompts in the terminal.")
                    }
                }

                Section("Destination") {
                    MenuPicker("Group", selection: $destination, options: destinationOptions)

                    if isCreatingGroup {
                        HStack {
                            TextField("New group name", text: $newGroupName)
                            Button("Add") { createGroup() }
                                .disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
                            Button("Cancel") {
                                isCreatingGroup = false
                                newGroupName = ""
                            }
                        }
                    } else {
                        Button("New Group…") { isCreatingGroup = true }
                    }
                }
            }
            .formStyle(.grouped)
            .onChange(of: type) { _, newType in
                if newType != .longRunning && newType != .oneShot {
                    isInteractiveCommand = false
                }
            }
        }
    }

    // MARK: - Pick rows

    @ViewBuilder
    private func pickSectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func scriptPickRow(_ option: WizardScriptOption) -> some View {
        DiscoveredCommandRow(
            name: option.name,
            sourceBadge: option.sourceLabel,
            commandPreview: option.commandPreview,
            isSelected: selectedPickId == option.id
        ) {
            selectedPickId = option.id
        }
    }

    private func artisanPickRow(_ option: WizardArtisanOption) -> some View {
        DiscoveredCommandRow(
            name: option.name,
            sourceBadge: "artisan",
            commandPreview: option.commandPreview,
            description: option.description,
            monospacedName: true,
            isSelected: selectedPickId == artisanQuickPickID(option.name)
        ) {
            selectedPickId = artisanQuickPickID(option.name)
        }
    }

    private func presetPickRow(_ item: PresetPickItem) -> some View {
        let displayName = CommandPresetApplier.makeProcess(from: item.command, project: project)?.name ?? item.command
        return DiscoveredCommandRow(
            name: displayName,
            sourceBadge: "preset",
            commandPreview: item.command,
            description: item.presetName,
            isSelected: selectedPickId == item.id
        ) {
            selectedPickId = item.id
        }
    }

    private var selectedSourceBadge: String? {
        guard let selectedPickId, selectedPickId != Self.customPickID else { return nil }
        if let script = scriptOptions.first(where: { $0.id == selectedPickId }) {
            return script.sourceLabel
        }
        if selectedPickId.hasPrefix("artisan:") {
            return "artisan"
        }
        if selectedPickId.hasPrefix("preset|") {
            return "preset"
        }
        return nil
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
            Spacer()
            if step == .configure, showPickStep {
                Button("Back") { step = .pick }
            }
            if step == .pick {
                Button("Next") { advanceFromPick() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedPickId == nil)
            } else {
                Button(isEditing ? "Save" : "Add") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
    }

    // MARK: - Actions

    private func artisanQuickPickID(_ name: String) -> String {
        "artisan:\(name)"
    }

    private static func presetPickID(presetId: UUID, commandIndex: Int) -> String {
        "preset|\(presetId.uuidString)|\(commandIndex)"
    }

    private static func parsePresetPickID(_ id: String) -> (UUID, Int)? {
        guard id.hasPrefix("preset|") else { return nil }
        let parts = id.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let presetId = UUID(uuidString: String(parts[1])),
              let commandIndex = Int(parts[2]) else { return nil }
        return (presetId, commandIndex)
    }

    private func loadDiscoveredCommands() async {
        let path = project.path
        let environment = project.environment
        let packageManager = project.packageManager

        scriptOptions = await Task.detached {
            ScriptCommandDiscovery.discover(
                at: path,
                environment: environment,
                packageManager: packageManager
            )
        }.value

        guard LaravelDetector.isLaravelProject(at: path) else {
            artisanOptions = []
            return
        }

        isLoadingDiscoveredCommands = true
        defer { isLoadingDiscoveredCommands = false }
        artisanOptions = await ArtisanCommandDiscovery.discover(
            at: path,
            environment: environment
        )
    }

    private func advanceFromPick() {
        guard let selectedPickId else { return }
        if selectedPickId == Self.customPickID {
            name = ""
            executable = ""
            argumentsText = ""
            type = .longRunning
            restartPolicy = .never
            autoStart = false
            isInteractiveCommand = false
            watchPathsText = ""
            watchDebounceMs = 500
        } else if selectedPickId == Self.folderWatchPickID {
            name = "Folder Watch"
            executable = "."
            argumentsText = ""
            type = .folderWatch
            restartPolicy = .never
            autoStart = false
            isInteractiveCommand = false
            watchPathsText = ""
            watchDebounceMs = 500
        } else {
            applyQuickPick(id: selectedPickId)
        }
        step = .configure
    }

    private func applyQuickPick(id: String) {
        if id.hasPrefix("npm:") || id.hasPrefix("composer:") {
            guard let option = scriptOptions.first(where: { $0.id == id }) else { return }
            applyScriptOption(option)
            return
        }
        if id.hasPrefix("artisan:") {
            let commandName = String(id.dropFirst("artisan:".count))
            guard let option = artisanOptions.first(where: { $0.name == commandName }) else { return }
            applyArtisanOption(option)
            return
        }
        if let (presetId, commandIndex) = Self.parsePresetPickID(id),
           let preset = appState.presets.first(where: { $0.id == presetId }),
           commandIndex < preset.commands.count {
            applyPresetCommand(preset.commands[commandIndex])
        }
    }

    private func applyPresetCommand(_ commandLine: String) {
        guard let definition = CommandPresetApplier.makeProcess(from: commandLine, project: project) else { return }
        name = definition.name
        executable = definition.executable
        argumentsText = definition.arguments.joined(separator: " ")
        type = definition.type
        restartPolicy = definition.restartPolicy
        autoStart = definition.autoStart
        applyOtherCommandsDestination(if: true)
    }

    private func applyScriptOption(_ option: WizardScriptOption) {
        let definition = ScriptCommandDiscovery.makeProcessDefinition(
            from: option,
            environment: project.environment,
            packageManager: project.packageManager
        )
        name = definition.name
        executable = definition.executable
        argumentsText = definition.arguments.joined(separator: " ")
        type = definition.type
        restartPolicy = definition.restartPolicy
        autoStart = definition.autoStart
        applyOtherCommandsDestination(if: option.useOtherCommandsGroup)
    }

    private func applyArtisanOption(_ option: WizardArtisanOption) {
        let definition = ArtisanCommandDiscovery.makeProcessDefinition(
            from: option,
            environment: project.environment,
            projectPath: project.path
        )
        name = definition.name
        executable = definition.executable
        argumentsText = definition.arguments.joined(separator: " ")
        type = definition.type
        restartPolicy = definition.restartPolicy
        autoStart = definition.autoStart
        applyOtherCommandsDestination(if: option.useOtherCommandsGroup)
    }

    private func applyOtherCommandsDestination(if useOtherCommands: Bool) {
        guard useOtherCommands, initialDestination == .processes else { return }
        guard let groupId = groups.first(where: { $0.name == ScriptCommandDiscovery.otherCommandsGroupName })?.id else {
            return
        }
        destination = .group(groupId)
    }

    private func createGroup() {
        let trimmed = newGroupName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Custom groups default to manual/on-demand, like the built-in "Other commands" —
        // Start All should never silently pick up something like a "Deploy" command.
        let group = ProcessGroup(name: trimmed, excludedFromStartAll: true)
        groups.append(group)

        var updated = project
        updated.processGroups = groups
        appState.updateProject(updated)

        destination = .group(group.id)
        newGroupName = ""
        isCreatingGroup = false
    }

    private func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: workingDirectory.isEmpty ? project.path : workingDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url.path
        }
    }

    private func parseEnvironment(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equalsIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[trimmed.startIndex..<equalsIndex].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    private func save() {
        let arguments = argumentsText.split(separator: " ").map(String.init)
        let trimmedWorkingDirectory = workingDirectory.trimmingCharacters(in: .whitespaces)
        let environment = isFolderWatch ? [:] : parseEnvironment(environmentText)
        let watchPaths = isFolderWatch ? parsedWatchPaths : []
        let debounce = isFolderWatch ? max(watchDebounceMs, 0) : 500
        let kind: ProcessKind = isFolderWatch ? .folderWatch : .custom
        let executableValue = isFolderWatch ? "." : executable
        let argumentsValue = isFolderWatch ? [] : arguments
        let restart = isFolderWatch ? RestartPolicy.never : restartPolicy
        let interactive = supportsInteractiveCommand && isInteractiveCommand

        var updated = project
        updated.processGroups = groups

        if let editingDefinitionId, let index = updated.processes.firstIndex(where: { $0.id == editingDefinitionId }) {
            updated.processes[index].name = name
            updated.processes[index].kind = kind
            updated.processes[index].executable = executableValue
            updated.processes[index].arguments = argumentsValue
            updated.processes[index].workingDirectory = isFolderWatch ? nil : (trimmedWorkingDirectory.isEmpty ? nil : trimmedWorkingDirectory)
            updated.processes[index].environment = environment
            updated.processes[index].type = type
            updated.processes[index].autoStart = autoStart
            updated.processes[index].isInteractiveCommand = interactive
            updated.processes[index].restartPolicy = restart
            updated.processes[index].groupId = destination.groupId
            updated.processes[index].role = destination.role
            updated.processes[index].watchPaths = watchPaths
            updated.processes[index].watchDebounceMs = debounce
        } else {
            let definition = ProcessDefinition(
                name: name,
                kind: kind,
                type: type,
                executable: executableValue,
                arguments: argumentsValue,
                workingDirectory: isFolderWatch ? nil : (trimmedWorkingDirectory.isEmpty ? nil : trimmedWorkingDirectory),
                environment: environment,
                autoStart: autoStart,
                restartPolicy: restart,
                groupId: destination.groupId,
                role: destination.role,
                watchPaths: watchPaths,
                watchDebounceMs: debounce,
                isInteractiveCommand: interactive
            )
            updated.processes.append(definition)
        }

        appState.updateProject(updated)
        dismiss()
    }
}
