import Foundation
import Observation

nonisolated enum ProcessStatus: String {
    case stopped
    case starting
    case running
    case stopping
    case failed
}

/// Runtime-only state for a process backed by a `ProcessDefinition`. Never persisted.
@Observable
final class RunningProcess: Identifiable {
    let id: UUID
    let projectId: UUID

    var status: ProcessStatus = .stopped
    var pid: Int32?
    var startTime: Date?
    var exitCode: Int32?

    /// Raw PTY output (including ANSI escape sequences), fed into a SwiftTerm `TerminalView`.
    let terminalBuffer = TerminalByteBuffer()

    /// Whether to post a user-facing start/stop notification for this run.
    var notifyActivity: Bool = true
    /// Whether to post a stop notification when this run is intentionally terminated.
    var notifyOnStop: Bool = true

    /// Foundation.Process instance backing this run, owned by ProcessManager.
    var task: Process?

    /// True while ProcessManager holds an open PTY master for stdin forwarding.
    var hasInteractivePTY = false

    /// Timestamps of recent auto-restarts, used for restart-loop protection.
    var restartTimestamps: [Date] = []

    init(id: UUID, projectId: UUID) {
        self.id = id
        self.projectId = projectId
    }

    func appendTerminalBytes(_ data: Data) {
        terminalBuffer.append(data)
    }

    /// Convenience for system-generated messages (e.g. "Process exited unexpectedly").
    func appendTerminalText(_ text: String) {
        terminalBuffer.appendText(text)
    }

    func clearTerminal() {
        terminalBuffer.clear()
    }

    /// Records a restart attempt and returns whether the loop-protection threshold was exceeded
    /// (more than 5 restarts within the trailing 60 seconds).
    func recordRestartAndCheckLoop() -> Bool {
        let now = Date()
        restartTimestamps.append(now)
        restartTimestamps.removeAll { now.timeIntervalSince($0) > 60 }
        return restartTimestamps.count > 5
    }
}
