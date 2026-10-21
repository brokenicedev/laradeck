import Foundation

/// FSEvents-backed path watch with per-watcher debounce.
///
/// - Directory paths: any change under the directory schedules a fire.
/// - File paths: the parent directory is watched, but a fire runs only when that
///   file's **content** changes. Trailing debounce waits until the fingerprint is
///   stable (Vite often rewrites manifest.json twice during one build).
@MainActor
final class FolderWatchService {
    private struct WatchTarget {
        let directoryPath: String
        let filePath: String?
    }

    /// Content-only identity (ignores mtime) for settle / last-fired comparisons.
    private struct ContentSignature: Equatable {
        var exists: Bool
        var size: Int64
        var contentHash: UInt64
    }

    private final class WatchSession {
        let sources: [DispatchSourceFileSystemObject]
        let directoryFDs: [Int32]
        let targets: [WatchTarget]
        var fileFingerprints: [String: FolderWatchFileFingerprint]
        /// Content signatures at the last emitted fire.
        var lastFiredContent: [String: ContentSignature] = [:]
        var debounceTask: Task<Void, Never>?
        let debounceMs: Int
        var suppressFires = false
        var dirtyWhileSuppressed = false
        var lastChangeNote: String?
        let onDebouncedChange: @MainActor () -> Void
        let onLog: (@MainActor (String) -> Void)?

        var hasFileTargets: Bool {
            targets.contains { $0.filePath != nil }
        }

        init(
            sources: [DispatchSourceFileSystemObject],
            directoryFDs: [Int32],
            targets: [WatchTarget],
            fileFingerprints: [String: FolderWatchFileFingerprint],
            debounceMs: Int,
            onDebouncedChange: @escaping @MainActor () -> Void,
            onLog: (@MainActor (String) -> Void)?
        ) {
            self.sources = sources
            self.directoryFDs = directoryFDs
            self.targets = targets
            self.fileFingerprints = fileFingerprints
            self.debounceMs = debounceMs
            self.onDebouncedChange = onDebouncedChange
            self.onLog = onLog
        }

        func log(_ message: String) {
            onLog?(message)
        }

        func cancel() {
            debounceTask?.cancel()
            debounceTask = nil
            for source in sources {
                source.cancel()
            }
            for fd in directoryFDs {
                close(fd)
            }
        }

        private func contentSignature(for fingerprint: FolderWatchFileFingerprint) -> ContentSignature {
            ContentSignature(
                exists: fingerprint.exists,
                size: fingerprint.size,
                contentHash: fingerprint.contentHash
            )
        }

        private func contentMap(
            from fingerprints: [String: FolderWatchFileFingerprint]
        ) -> [String: ContentSignature] {
            Dictionary(uniqueKeysWithValues: fingerprints.map { ($0.key, contentSignature(for: $0.value)) })
        }

        private func describe(_ fingerprint: FolderWatchFileFingerprint) -> String {
            if !fingerprint.exists {
                return "missing"
            }
            let mtime = Date(timeIntervalSince1970: fingerprint.modificationTime)
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            return "size=\(fingerprint.size) hash=\(String(fingerprint.contentHash, radix: 16)) mtime=\(formatter.string(from: mtime))"
        }

        @discardableResult
        func refreshFileFingerprints() -> (changed: Bool, note: String?) {
            let fileTargets = targets.compactMap(\.filePath)
            guard !fileTargets.isEmpty else { return (true, nil) }

            var changed = false
            var notes: [String] = []
            for path in fileTargets {
                let next = FolderWatchPathResolver.fileFingerprint(for: path)
                let previous = fileFingerprints[path]
                let name = (path as NSString).lastPathComponent
                let previousContent = previous.map(contentSignature(for:))
                let nextContent = contentSignature(for: next)

                if previousContent != nextContent {
                    let before = previous.map(describe) ?? "nil"
                    let after = describe(next)
                    notes.append("\(name): \(before) → \(after)")
                    log("watch content change · \(name): \(before) → \(after)")
                    fileFingerprints[path] = next
                    changed = true
                } else if previous != next {
                    // mtime / metadata only
                    log(
                        "watch ignored (mtime/meta only) · \(name): \(previous.map(describe) ?? "nil") → \(describe(next))"
                    )
                    fileFingerprints[path] = next
                }
            }
            return (changed, notes.isEmpty ? nil : notes.joined(separator: " | "))
        }

        func handleFilesystemEvent() {
            if hasFileTargets {
                let result = refreshFileFingerprints()
                guard result.changed else { return }
                if suppressFires {
                    dirtyWhileSuppressed = true
                    log("watch absorbed (nested run in progress) · \(result.note ?? "content change")")
                    return
                }
                lastChangeNote = result.note
                scheduleFire()
                return
            }

            if suppressFires {
                dirtyWhileSuppressed = true
                log("watch absorbed (nested run in progress) · directory event")
                return
            }
            lastChangeNote = "directory change"
            log("watch directory event · scheduling settle (\(debounceMs)ms)")
            scheduleFire()
        }

        func scheduleFire() {
            debounceTask?.cancel()
            let delay = max(debounceMs, 0)
            log("watch settle started · quiet window \(delay)ms")
            debounceTask = Task { @MainActor in
                if hasFileTargets {
                    // Wait until content is quiet. If it settles on missing/empty, keep waiting
                    // for Vite to rewrite the file instead of treating deletion as a fire.
                    var round = 0
                    while !Task.isCancelled {
                        let snapshot = contentMap(from: fileFingerprints)
                        if delay > 0 {
                            try? await Task.sleep(for: .milliseconds(delay))
                        }
                        guard !Task.isCancelled else { return }
                        refreshFileFingerprints()
                        let current = contentMap(from: fileFingerprints)
                        if current == snapshot {
                            if current.values.allSatisfy({ !$0.exists || $0.size == 0 }) {
                                round += 1
                                log("watch settle · still missing/empty after quiet window (round \(round)) — waiting for rewrite")
                                continue
                            }
                            log("watch settle stable after \(round + 1) quiet window(s)")
                            break
                        }
                        round += 1
                        log("watch settle extended · content still changing (round \(round))")
                    }
                } else if delay > 0 {
                    try? await Task.sleep(for: .milliseconds(delay))
                }

                guard !Task.isCancelled else {
                    log("watch settle cancelled")
                    return
                }
                if suppressFires {
                    dirtyWhileSuppressed = true
                    log("watch fire deferred · nested run still active")
                    return
                }
                if hasFileTargets {
                    refreshFileFingerprints()
                    let current = contentMap(from: fileFingerprints)

                    // Vite deletes / truncates the manifest mid-build then rewrites it.
                    // Never fire on missing/empty — wait for a real settled file.
                    if current.values.allSatisfy({ !$0.exists || $0.size == 0 }) {
                        log("watch fire skipped · file missing/empty (likely mid-build); keeping last good fingerprint")
                        return
                    }

                    if current == lastFiredContent {
                        log("watch fire skipped · content unchanged since last fire")
                        return
                    }
                    for (path, signature) in current {
                        let name = (path as NSString).lastPathComponent
                        let previous = lastFiredContent[path]
                        log(
                            "watch fire · \(name): was \(previous.map { "size=\($0.size) hash=\(String($0.contentHash, radix: 16))" } ?? "nil") now size=\(signature.size) hash=\(String(signature.contentHash, radix: 16))"
                        )
                    }
                    lastFiredContent = current
                } else {
                    log("watch fire · directory settle complete")
                }
                onDebouncedChange()
            }
        }
    }

    private var sessions: [UUID: WatchSession] = [:]

    /// Starts watching resolved file/directory paths. Returns an error message if nothing could be watched.
    @discardableResult
    func start(
        id: UUID,
        directoryPaths: [String],
        debounceMs: Int,
        onDebouncedChange: @escaping @MainActor () -> Void,
        onLog: (@MainActor (String) -> Void)? = nil
    ) -> String? {
        stop(id: id)

        var targets: [WatchTarget] = []
        var failures: [String] = []

        for path in Array(Set(directoryPaths)) {
            guard let kind = FolderWatchPathResolver.classify(path) else {
                failures.append("Missing: \(path)")
                continue
            }
            switch kind {
            case .directory(let directory):
                targets.append(WatchTarget(directoryPath: directory, filePath: nil))
            case .file(let directory, let file):
                targets.append(WatchTarget(directoryPath: directory, filePath: file))
            }
        }

        var sources: [DispatchSourceFileSystemObject] = []
        var fds: [Int32] = []
        var openedDirectories = Set<String>()

        for directoryPath in Set(targets.map(\.directoryPath)) {
            guard !openedDirectories.contains(directoryPath) else { continue }
            let fd = open(directoryPath, O_EVTONLY)
            guard fd >= 0 else {
                failures.append("Cannot open: \(directoryPath)")
                continue
            }
            openedDirectories.insert(directoryPath)

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke, .link],
                queue: DispatchQueue.main
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    self?.sessions[id]?.handleFilesystemEvent()
                }
            }
            source.setCancelHandler {
                // FD closed in session.cancel()
            }
            source.resume()
            sources.append(source)
            fds.append(fd)
        }

        let openDirs = openedDirectories
        targets = targets.filter { openDirs.contains($0.directoryPath) }

        guard !sources.isEmpty else {
            let detail = failures.isEmpty ? "No watch paths configured." : failures.joined(separator: "; ")
            return detail
        }

        var fingerprints: [String: FolderWatchFileFingerprint] = [:]
        for filePath in targets.compactMap(\.filePath) {
            fingerprints[filePath] = FolderWatchPathResolver.fileFingerprint(for: filePath)
        }

        let session = WatchSession(
            sources: sources,
            directoryFDs: fds,
            targets: targets,
            fileFingerprints: fingerprints,
            debounceMs: debounceMs,
            onDebouncedChange: onDebouncedChange,
            onLog: onLog
        )
        session.lastFiredContent = Dictionary(
            uniqueKeysWithValues: fingerprints.map {
                (
                    $0.key,
                    ContentSignature(exists: $0.value.exists, size: $0.value.size, contentHash: $0.value.contentHash)
                )
            }
        )
        sessions[id] = session

        let kinds = targets.map { target -> String in
            if let file = target.filePath {
                return "file:\((file as NSString).lastPathComponent)"
            }
            return "dir:\((target.directoryPath as NSString).lastPathComponent)"
        }
        onLog?("watch armed · \(kinds.joined(separator: ", ")) · debounce \(max(debounceMs, 0))ms")

        return failures.isEmpty ? nil : "Watching with warnings: \(failures.joined(separator: "; "))"
    }

    func stop(id: UUID) {
        sessions.removeValue(forKey: id)?.cancel()
    }

    func stopAll() {
        for id in Array(sessions.keys) {
            stop(id: id)
        }
    }

    func beginSuppressing(id: UUID) {
        guard let session = sessions[id] else { return }
        session.suppressFires = true
        session.dirtyWhileSuppressed = false
        session.debounceTask?.cancel()
        session.debounceTask = nil
        session.log("watch suppress on · nested children running")
    }

    func endSuppressing(id: UUID) {
        guard let session = sessions[id] else { return }
        let dirty = session.dirtyWhileSuppressed
        session.suppressFires = false
        session.dirtyWhileSuppressed = false
        session.log("watch suppress off · dirty=\(dirty)")
        if dirty {
            session.refreshFileFingerprints()
            if session.hasFileTargets {
                let current = Dictionary(
                    uniqueKeysWithValues: session.fileFingerprints.map {
                        (
                            $0.key,
                            ContentSignature(
                                exists: $0.value.exists,
                                size: $0.value.size,
                                contentHash: $0.value.contentHash
                            )
                        )
                    }
                )
                if current != session.lastFiredContent {
                    session.lastChangeNote = "change during nested run — waiting for settle"
                    session.log("watch re-arm after nested run · content differs from last fire")
                    session.scheduleFire()
                } else {
                    session.log("watch re-arm skipped · content matches last fire")
                }
            } else {
                session.lastChangeNote = "change during nested run — waiting for settle"
                session.scheduleFire()
            }
        }
    }

    func consumeChangeNote(id: UUID) -> String? {
        guard let session = sessions[id] else { return nil }
        let note = session.lastChangeNote
        session.lastChangeNote = nil
        return note
    }
}
