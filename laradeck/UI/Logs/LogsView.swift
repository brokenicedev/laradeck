import SwiftUI

/// Full-screen log viewer (replaces the dashboard in place, same pattern as `EnvEditorView`) — one
/// real terminal per source, Laravel log included, so everything looks and behaves the same way.
struct LogsView: View {
    @Environment(AppState.self) private var appState
    let project: Project
    let onDone: () -> Void

    @State private var selectedSource: String

    init(project: Project, initialSource: String = LogManager.laravelSource, onDone: @escaping () -> Void) {
        self.project = project
        self.onDone = onDone
        _selectedSource = State(initialValue: initialSource)
    }

    private var sources: [String] {
        var result = [LogManager.laravelSource]
        if project.hasDockerCompose {
            for service in appState.dockerManager.statusByProject[project.id] ?? [] {
                let source = LogManager.containerSource(service.name)
                if !result.contains(source) {
                    result.append(source)
                }
            }
        }
        for definition in project.processes where !result.contains(definition.name) {
            result.append(definition.name)
        }
        return result
    }

    private var isLaravelSource: Bool {
        selectedSource == LogManager.laravelSource
    }

    private var isContainerSource: Bool {
        LogManager.isContainerSource(selectedSource)
    }

    private var terminalSource: TerminalBufferSource? {
        if isLaravelSource {
            return appState.logManager.laravelBuffer(for: project.id)
        }
        if isContainerSource, let service = LogManager.serviceName(fromContainerSource: selectedSource) {
            return appState.dockerManager.containerLogBuffer(projectId: project.id, service: service)
        }
        guard let definition = project.processes.first(where: { $0.name == selectedSource }) else { return nil }
        return appState.processManager.runningProcess(for: definition.id)?.terminalBuffer
    }

    private var selectedProcessDefinition: ProcessDefinition? {
        guard !isLaravelSource, !isContainerSource else { return nil }
        return project.processes.first(where: { $0.name == selectedSource })
    }

    private var isInteractiveProcessLog: Bool {
        guard let definition = selectedProcessDefinition,
              definition.isInteractiveCommand else { return false }
        return appState.processManager.supportsInteractiveStdin(for: definition.id)
    }

    private var showsInteractiveCommandUI: Bool {
        selectedProcessDefinition?.isInteractiveCommand == true
    }

    private var selectedProcessStatus: ProcessStatus? {
        guard let definition = selectedProcessDefinition else { return nil }
        return appState.processManager.status(for: definition.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                MenuPicker(
                    selection: $selectedSource,
                    options: sources.map { sourceName in
                        let label: String
                        if let definition = project.processes.first(where: { $0.name == sourceName }),
                           definition.isInteractiveCommand {
                            label = "\(sourceName) · Interactive"
                        } else {
                            label = sourceName
                        }
                        return (sourceName, label)
                    }
                )
                .frame(minWidth: 160, maxWidth: 320, alignment: .leading)
                .layoutPriority(0)

                Spacer(minLength: 12)

                Button {
                    clearCurrentSource()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.laradeckOutline(accent: .red))
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            }

            if showsInteractiveCommandUI {
                if isInteractiveProcessLog {
                    NoticeBanner(
                        tone: .info,
                        message: "Click the terminal below and type to answer prompts."
                    )
                } else if selectedProcessStatus == .starting || selectedProcessStatus == .running {
                    NoticeBanner(
                        tone: .info,
                        message: "Interactive command is starting — input will be enabled shortly."
                    )
                } else {
                    NoticeBanner(
                        tone: .info,
                        message: "Interactive command — start the process, then type here to respond to prompts."
                    )
                }
            } else if terminalSource == nil || (terminalSource?.terminalData.isEmpty ?? true) {
                NoticeBanner(tone: .info, message: "No output yet for this source. Start the process or refresh container logs.")
            }

            TerminalOutputView(
                source: terminalSource,
                isInteractive: isInteractiveProcessLog,
                isActive: selectedProcessStatus.map { $0 != .stopped && $0 != .failed } ?? true,
                onSend: { bytes in
                    guard let definition = selectedProcessDefinition else { return }
                    appState.processManager.writeStdin(to: definition.id, data: Data(bytes))
                },
                onSizeChanged: { cols, rows in
                    guard let definition = selectedProcessDefinition else { return }
                    appState.processManager.setTerminalSize(for: definition.id, cols: cols, rows: rows)
                }
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if isInteractiveProcessLog {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(InteractiveCommandBadge.tint.opacity(0.55), lineWidth: 2)
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.quaternary, lineWidth: 1)
                    }
                }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LaradeckTheme.pageBackground)
        .laradeckTitle("\(project.name) — Logs")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    onDone()
                } label: {
                    Label("Dashboard", systemImage: "chevron.left")
                }
            }
        }
        .task(id: selectedSource) {
            await updateContainerTailing()
        }
        .onDisappear {
            appState.dockerManager.stopContainerLogTails(for: project.id)
        }
    }

    private func updateContainerTailing() async {
        appState.dockerManager.stopContainerLogTails(for: project.id)
        guard isContainerSource,
              let service = LogManager.serviceName(fromContainerSource: selectedSource) else {
            return
        }
        await appState.dockerManager.startTailingContainerLogs(for: project, service: service)
    }

    private func clearCurrentSource() {
        if isLaravelSource {
            appState.logManager.laravelBuffer(for: project.id).clear()
        } else if isContainerSource,
                  let service = LogManager.serviceName(fromContainerSource: selectedSource) {
            appState.dockerManager.containerLogBuffer(projectId: project.id, service: service).clear()
        } else if let definition = project.processes.first(where: { $0.name == selectedSource }) {
            appState.processManager.runningProcess(for: definition.id)?.clearTerminal()
        }
    }
}
