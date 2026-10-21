import Foundation
import Darwin
import Observation

/// Tails a project's Laravel log into a `TerminalByteBuffer`, rendered the same way as live
/// process output (spec-consistent look across every log source).
@MainActor
@Observable
final class LogManager {
    static let laravelSource = "Laravel"
    static let containerSourcePrefix = "Container · "

    static func containerSource(_ serviceName: String) -> String {
        containerSourcePrefix + serviceName
    }

    static func isContainerSource(_ source: String) -> Bool {
        source.hasPrefix(containerSourcePrefix)
    }

    static func serviceName(fromContainerSource source: String) -> String? {
        guard isContainerSource(source) else { return nil }
        let name = String(source.dropFirst(containerSourcePrefix.count))
        return name.isEmpty ? nil : name
    }

    private(set) var laravelBuffers: [UUID: TerminalByteBuffer] = [:]

    /// Watches the whole `storage/logs` directory (not a fixed "laravel.log" path) and always
    /// follows whichever `*.log` file was modified most recently — `LOG_CHANNEL=daily` writes to
    /// a new dated file each day, and a fixed filename would silently stop updating once that
    /// happens.
    private struct LaravelTailState {
        var directorySource: DispatchSourceFileSystemObject?
        var fileSource: DispatchSourceFileSystemObject?
        var fileHandle: FileHandle?
        var currentPath: String?
    }

    private var laravelTailStates: [UUID: LaravelTailState] = [:]

    func laravelBuffer(for projectId: UUID) -> TerminalByteBuffer {
        if let existing = laravelBuffers[projectId] { return existing }
        let buffer = TerminalByteBuffer()
        laravelBuffers[projectId] = buffer
        return buffer
    }

    func startTailingLaravelLog(for project: Project) {
        stopTailingLaravelLog(project: project.id)

        let logsDir = (project.path as NSString).appendingPathComponent("storage/logs")
        guard FileManager.default.fileExists(atPath: logsDir) else { return }

        let projectId = project.id
        var state = LaravelTailState()

        let dirFD = open(logsDir, O_EVTONLY)
        if dirFD >= 0 {
            let directorySource = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: dirFD,
                eventMask: .write,
                queue: .global(qos: .utility)
            )
            directorySource.setEventHandler { [weak self] in
                Task { @MainActor in
                    self?.refreshLaravelTailTarget(projectId: projectId, logsDir: logsDir)
                }
            }
            directorySource.setCancelHandler {
                close(dirFD)
            }
            directorySource.resume()
            state.directorySource = directorySource
        }

        laravelTailStates[projectId] = state
        refreshLaravelTailTarget(projectId: projectId, logsDir: logsDir)
    }

    func stopTailingLaravelLog(project projectId: UUID) {
        guard let state = laravelTailStates[projectId] else { return }
        state.fileSource?.cancel()
        state.directorySource?.cancel()
        laravelTailStates.removeValue(forKey: projectId)
    }

    /// Re-checks `storage/logs` for the newest `*.log` file and, if it's different from what's
    /// currently being tailed, switches the file-level watcher over to it.
    private func refreshLaravelTailTarget(projectId: UUID, logsDir: String) {
        guard var state = laravelTailStates[projectId] else { return }

        guard let filenames = try? FileManager.default.contentsOfDirectory(atPath: logsDir) else { return }
        let newestPath = filenames
            .filter { $0.hasSuffix(".log") }
            .map { (logsDir as NSString).appendingPathComponent($0) }
            .max { Self.modificationDate($0) < Self.modificationDate($1) }

        guard let newestPath, newestPath != state.currentPath else { return }

        state.fileSource?.cancel()
        state.fileSource = nil
        state.fileHandle = nil
        state.currentPath = newestPath

        guard let handle = FileHandle(forReadingAtPath: newestPath) else {
            laravelTailStates[projectId] = state
            return
        }
        handle.seekToEndOfFile()

        let buffer = laravelBuffer(for: projectId)
        let fileSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor,
            eventMask: .extend,
            queue: .global(qos: .utility)
        )
        fileSource.setEventHandler {
            let newData = handle.availableData
            guard !newData.isEmpty else { return }
            Task { @MainActor in
                buffer.appendLogStream(newData)
            }
        }
        fileSource.setCancelHandler {
            try? handle.close()
        }
        fileSource.resume()

        state.fileSource = fileSource
        state.fileHandle = handle
        laravelTailStates[projectId] = state
    }

    private static func modificationDate(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date.distantPast
    }
}
