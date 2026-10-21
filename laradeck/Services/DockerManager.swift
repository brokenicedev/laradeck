import Foundation
import Observation

nonisolated struct DockerServiceStatus: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let state: String
    let health: String?
    let ports: [Int]
    let exitCode: Int?

    var isRunning: Bool { state.lowercased() == "running" }
    var isRestarting: Bool { state.lowercased() == "restarting" }
    var isDead: Bool { state.lowercased() == "dead" }
    var isUnhealthy: Bool { health?.lowercased() == "unhealthy" }
    var isHealthCheckStarting: Bool { health?.lowercased() == "starting" }
    /// A container that stopped on its own with a non-zero exit code, as opposed to one we (or
    /// the user) stopped intentionally via "Sail Down".
    var exitedWithError: Bool { state.lowercased() == "exited" && (exitCode ?? 0) != 0 }
}

nonisolated struct DockerCommandResult {
    let success: Bool
    /// Combined stdout+stderr — whatever `docker compose` printed, useful to show on failure.
    let output: String
}

nonisolated enum DockerDaemonState: Equatable {
    case unknown
    case running
    case stopped
    case notInstalled

    var label: String {
        switch self {
        case .unknown: return "Checking Docker…"
        case .running: return "Docker is running"
        case .stopped: return "Docker is stopped"
        case .notInstalled: return "Docker command not found"
        }
    }

    var shortLabel: String {
        switch self {
        case .unknown: return "Checking…"
        case .running: return "Docker running"
        case .stopped: return "Docker stopped"
        case .notInstalled: return "Docker not found"
        }
    }
}

/// Wraps the Docker CLI (`docker compose ...`) to control and inspect container stacks.
@MainActor
@Observable
final class DockerManager {
    private let runtimeResolver = RuntimeResolver.shared
    private let notificationManager: NotificationManager

    private(set) var statusByProject: [UUID: [DockerServiceStatus]] = [:]
    private(set) var busyProjectIds: Set<UUID> = []
    /// Set centrally by `runCompose`, so every trigger (the panel's own buttons, Start/Stop All
    /// from the toolbar or menu bar) surfaces the same feedback — not just whichever call site
    /// happened to check the result.
    private(set) var lastErrorByProject: [UUID: String] = [:]
    private(set) var daemonState: DockerDaemonState = .unknown
    private(set) var containerLogBuffers: [String: TerminalByteBuffer] = [:]
    private(set) var composeOutputBuffers: [UUID: TerminalByteBuffer] = [:]

    private var containerLogProcesses: [String: Process] = [:]

    static let daemonUnavailableMessage = "Docker isn't running — start Docker Desktop to use Compose projects."

    init(notificationManager: NotificationManager) {
        self.notificationManager = notificationManager
    }

    var isDaemonRunning: Bool { daemonState == .running }

    func refreshDaemonState() async {
        guard let dockerPath = await runtimeResolver.resolvePath(for: "docker") else {
            daemonState = .notInstalled
            return
        }

        let (success, _) = await run(
            executable: dockerPath,
            arguments: ["info"],
            workingDirectory: NSHomeDirectory()
        )
        daemonState = success ? .running : .stopped
    }

    func resetDaemonState() {
        daemonState = .unknown
    }

    func reportDaemonUnavailable(for project: Project) {
        lastErrorByProject[project.id] = Self.daemonUnavailableMessage
        notificationManager.notifyDockerFailure(
            projectName: project.name,
            message: Self.daemonUnavailableMessage
        )
    }

    func isBusy(_ projectId: UUID) -> Bool {
        busyProjectIds.contains(projectId)
    }

    func clearError(for projectId: UUID) {
        lastErrorByProject.removeValue(forKey: projectId)
    }

    func composeOutputBuffer(for projectId: UUID) -> TerminalByteBuffer {
        if let existing = composeOutputBuffers[projectId] { return existing }
        let buffer = TerminalByteBuffer()
        composeOutputBuffers[projectId] = buffer
        return buffer
    }

    func clearComposeOutput(for projectId: UUID) {
        composeOutputBuffer(for: projectId).clear()
    }

    func refreshStatus(for project: Project) async {
        let statuses = await composeStatus(projectPath: project.path)
        statusByProject[project.id] = statuses
    }

    /// Refreshes container status for every project with a Compose file (Sail or plain docker compose).
    func refreshAllComposeStatuses(for projects: [Project]) async {
        guard isDaemonRunning else { return }
        for project in projects where project.hasDockerCompose {
            await refreshStatus(for: project)
        }
    }

    func containerLogBuffer(projectId: UUID, service: String) -> TerminalByteBuffer {
        let key = containerLogKey(projectId: projectId, service: service)
        if let existing = containerLogBuffers[key] { return existing }
        let buffer = TerminalByteBuffer()
        containerLogBuffers[key] = buffer
        return buffer
    }

    func startTailingContainerLogs(for project: Project, service: String) async {
        guard isDaemonRunning else { return }
        let key = containerLogKey(projectId: project.id, service: service)
        stopTailingContainerLogs(projectId: project.id, service: service)

        guard let dockerPath = await runtimeResolver.resolvePath(for: "docker") else { return }
        let buffer = containerLogBuffer(projectId: project.id, service: service)
        buffer.clear()

        var environment = await runtimeResolver.loginShellEnvironment()
        if environment.isEmpty {
            environment = ProcessInfo.processInfo.environment
        }
        environment["NO_COLOR"] = "1"
        environment["CLICOLOR"] = "0"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: dockerPath)
        process.arguments = [
            "compose", "logs", "-f", "--tail=300", "--no-color", "--no-log-prefix", service,
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: project.path, isDirectory: true)
        process.environment = environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                buffer.appendLogStream(data)
            }
        }

        process.terminationHandler = { _ in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                self.containerLogProcesses.removeValue(forKey: key)
            }
        }

        do {
            try process.run()
            containerLogProcesses[key] = process
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            buffer.appendText("Failed to tail container logs: \(error.localizedDescription)")
        }
    }

    func stopTailingContainerLogs(projectId: UUID, service: String) {
        let key = containerLogKey(projectId: projectId, service: service)
        guard let process = containerLogProcesses.removeValue(forKey: key) else { return }
        if process.isRunning {
            process.terminate()
        }
    }

    func stopContainerLogTails(for projectId: UUID) {
        let prefix = "\(projectId.uuidString)|"
        let keys = containerLogProcesses.keys.filter { $0.hasPrefix(prefix) }
        for key in keys {
            if let process = containerLogProcesses.removeValue(forKey: key), process.isRunning {
                process.terminate()
            }
        }
    }

    private func containerLogKey(projectId: UUID, service: String) -> String {
        "\(projectId.uuidString)|\(service)"
    }

    func composeStatus(projectPath: String) async -> [DockerServiceStatus] {
        guard let dockerPath = await runtimeResolver.resolvePath(for: "docker") else { return [] }
        // --all so stopped containers (e.g. after a per-service Stop) still show up — otherwise
        // they'd vanish from the list instead of offering a way back to Play.
        let (_, output) = await run(executable: dockerPath, arguments: ["compose", "ps", "--all", "--format", "json"], workingDirectory: projectPath)
        guard !output.isEmpty else { return [] }

        var results: [DockerServiceStatus] = []
        for line in output.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let name = (object["Service"] as? String) ?? (object["Name"] as? String) ?? "unknown"
            let state = (object["State"] as? String) ?? "unknown"
            let rawHealth = object["Health"] as? String
            let ports = Self.publishedPorts(from: object)
            let exitCode = object["ExitCode"] as? Int
            results.append(DockerServiceStatus(
                name: name,
                state: state,
                health: (rawHealth?.isEmpty ?? true) ? nil : rawHealth,
                ports: ports,
                exitCode: exitCode
            ))
        }
        return results
    }

    /// Modern `docker compose ps --format json` reports a structured "Publishers" array; older
    /// versions only give a "Ports" string like "0.0.0.0:3306->3306/tcp, :::3306->3306/tcp".
    private static func publishedPorts(from object: [String: Any]) -> [Int] {
        var ports: [Int] = []

        if let publishers = object["Publishers"] as? [[String: Any]] {
            for publisher in publishers {
                if let published = parsePortNumber(publisher["PublishedPort"]), published > 0 {
                    ports.append(published)
                }
            }
        } else if let portsString = object["Ports"] as? String {
            ports = parsePortsString(portsString)
        }

        return Array(Set(ports)).sorted()
    }

    private static func parsePortNumber(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let double as Double:
            return Int(double)
        case let string as String:
            return Int(string)
        case let number as NSNumber:
            return number.intValue
        default:
            return nil
        }
    }

    private static func parsePortsString(_ raw: String) -> [Int] {
        var results: [Int] = []
        for segment in raw.split(separator: ",") {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            guard let arrowRange = trimmed.range(of: "->") else { continue }
            let hostPart = trimmed[trimmed.startIndex..<arrowRange.lowerBound]
            guard let colonIndex = hostPart.lastIndex(of: ":") else { continue }
            let portString = hostPart[hostPart.index(after: colonIndex)...]
            if let port = Int(portString) {
                results.append(port)
            }
        }
        return results
    }

    @discardableResult
    func up(for project: Project) async -> DockerCommandResult {
        guard isDaemonRunning else {
            let result = DockerCommandResult(success: false, output: Self.daemonUnavailableMessage)
            lastErrorByProject[project.id] = result.output
            notificationManager.notifyDockerFailure(projectName: project.name, message: result.output)
            return result
        }
        return await runCompose(["up", "-d"], for: project)
    }

    @discardableResult
    func down(for project: Project) async -> DockerCommandResult {
        await runCompose(["down"], for: project)
    }

    @discardableResult
    func restart(for project: Project) async -> DockerCommandResult {
        await runCompose(["restart"], for: project)
    }

    @discardableResult
    func restart(for project: Project, service: String) async -> DockerCommandResult {
        await runCompose(["restart", service], for: project)
    }

    /// Stops (but doesn't remove) a single container — `docker compose down` tears down the
    /// whole stack, this only affects one service, mirroring the per-process Stop button.
    @discardableResult
    func stop(for project: Project, service: String) async -> DockerCommandResult {
        await runCompose(["stop", service], for: project)
    }

    /// Starts a single previously-stopped container without recreating it (or the rest of the stack).
    @discardableResult
    func start(for project: Project, service: String) async -> DockerCommandResult {
        await runCompose(["start", service], for: project)
    }

    @discardableResult
    func build(for project: Project) async -> DockerCommandResult {
        await runCompose(["build", "--progress=plain"], for: project)
    }

    private func runCompose(_ arguments: [String], for project: Project) async -> DockerCommandResult {
        busyProjectIds.insert(project.id)
        defer { busyProjectIds.remove(project.id) }

        guard let dockerPath = await runtimeResolver.resolvePath(for: "docker") else {
            let result = DockerCommandResult(
                success: false,
                output: "Could not find the \"docker\" command — is Docker installed and in your PATH?"
            )
            lastErrorByProject[project.id] = result.output
            notificationManager.notifyDockerFailure(projectName: project.name, message: result.output)
            return result
        }

        let buffer = composeOutputBuffer(for: project.id)
        buffer.clear()
        buffer.appendText("$ docker compose " + arguments.joined(separator: " "))

        let (success, output) = await runStreaming(
            executable: dockerPath,
            arguments: ["compose"] + arguments,
            workingDirectory: project.path
        ) { data in
            buffer.appendLogStream(data)
        }

        if success {
            lastErrorByProject.removeValue(forKey: project.id)
            if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                buffer.appendText("✓ Command completed successfully.")
            }
        } else {
            let message = output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Command failed (exit code non-zero)."
                : output
            lastErrorByProject[project.id] = message
            notificationManager.notifyDockerFailure(projectName: project.name, message: message)
        }
        return DockerCommandResult(success: success, output: output)
    }

    /// Streams stdout+stderr while the process runs so long compose pulls/builds stay visible in the UI.
    private func runStreaming(
        executable: String,
        arguments: [String],
        workingDirectory: String,
        onOutput: @escaping @MainActor (Data) -> Void
    ) async -> (success: Bool, output: String) {
        var environment = await runtimeResolver.loginShellEnvironment()
        if environment.isEmpty {
            environment = ProcessInfo.processInfo.environment
        }
        environment["NO_COLOR"] = "1"
        environment["CLICOLOR"] = "0"
        environment["DOCKER_CLI_HINTS"] = "false"

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            process.environment = environment

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            let collector = OutputCollector()
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                collector.append(data)
                Task { @MainActor in
                    onOutput(data)
                }
            }

            process.terminationHandler = { finishedProcess in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: (finishedProcess.terminationStatus == 0, collector.text))
            }

            do {
                try process.run()
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: (false, error.localizedDescription))
            }
        }
    }

    /// Buffers output until the process exits — fine for quick commands like `docker compose ps`.
    private func run(executable: String, arguments: [String], workingDirectory: String) async -> (success: Bool, output: String) {
        var environment = await runtimeResolver.loginShellEnvironment()
        if environment.isEmpty {
            environment = ProcessInfo.processInfo.environment
        }

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            process.environment = environment

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            let collector = OutputCollector()
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                collector.append(data)
            }

            process.terminationHandler = { finishedProcess in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: (finishedProcess.terminationStatus == 0, collector.text))
            }

            do {
                try process.run()
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: (false, error.localizedDescription))
            }
        }
    }
}

/// Accumulates process output from a background readability-handler queue and the termination
/// handler, which may run on different threads.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
