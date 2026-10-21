import SwiftUI

/// Dark log panel docked under a project's dashboard: pick a source (Laravel log, a process,
/// a container) and follow it. Read-only — interactive commands use the full Logs screen.
struct ProjectLogPanel: View {
    @Environment(AppState.self) private var appState
    let project: Project
    let onOpenFullLogs: (String) -> Void

    @AppStorage("projectLogPanelSource") private var storedSource = LogManager.laravelSource

    private var sources: [String] {
        var result = [LogManager.laravelSource]
        if project.hasDockerCompose {
            for service in appState.dockerManager.statusByProject[project.id] ?? [] {
                let source = LogManager.containerSource(service.name)
                if !result.contains(source) { result.append(source) }
            }
        }
        for definition in project.processes where !result.contains(definition.name) {
            result.append(definition.name)
        }
        return result
    }

    /// Falls back to the Laravel log when the stored source isn't in this project.
    private var source: String {
        sources.contains(storedSource) ? storedSource : LogManager.laravelSource
    }

    private var terminalSource: TerminalBufferSource? {
        if source == LogManager.laravelSource {
            return appState.logManager.laravelBuffer(for: project.id)
        }
        if LogManager.isContainerSource(source), let service = LogManager.serviceName(fromContainerSource: source) {
            return appState.dockerManager.containerLogBuffer(projectId: project.id, service: service)
        }
        guard let definition = project.processes.first(where: { $0.name == source }) else { return nil }
        return appState.processManager.runningProcess(for: definition.id)?.terminalBuffer
    }

    private var isActive: Bool {
        guard let definition = project.processes.first(where: { $0.name == source }) else { return true }
        let status = appState.processManager.status(for: definition.id)
        return status != .stopped && status != .failed
    }

    var body: some View {
        LogPanel(onClear: clear) {
            Menu {
                ForEach(sources, id: \.self) { name in
                    Button {
                        storedSource = name
                    } label: {
                        if name == source { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
            } label: {
                Text(source)
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Log source")

            Button {
                onOpenFullLogs(source)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LogPanelStyle.secondary)
            }
            .buttonStyle(.plain)
            .help("Open full Logs (interactive commands, all sources)")
        } content: {
            if terminalSource?.terminalData.isEmpty ?? true {
                Text("No output yet for \(source).")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(LogPanelStyle.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            } else {
                TerminalOutputView(source: terminalSource, isActive: isActive, usesPanelColors: true)
                    .padding(.leading, 8)
            }
        }
        .task(id: source) {
            appState.dockerManager.stopContainerLogTails(for: project.id)
            if LogManager.isContainerSource(source), let service = LogManager.serviceName(fromContainerSource: source) {
                await appState.dockerManager.startTailingContainerLogs(for: project, service: service)
            }
        }
    }

    private func clear() {
        if source == LogManager.laravelSource {
            appState.logManager.laravelBuffer(for: project.id).clear()
        } else if LogManager.isContainerSource(source), let service = LogManager.serviceName(fromContainerSource: source) {
            appState.dockerManager.containerLogBuffer(projectId: project.id, service: service).clear()
        } else if let definition = project.processes.first(where: { $0.name == source }) {
            appState.processManager.runningProcess(for: definition.id)?.clearTerminal()
        }
    }
}
