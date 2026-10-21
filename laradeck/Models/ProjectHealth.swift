import Foundation

/// Overall project status shown in the sidebar and menu bar (spec §38).
nonisolated enum ProjectHealth {
    /// All configured long-running processes are running.
    case running
    /// Some are running, some are not.
    case attention
    /// At least one process failed.
    case error
    /// Nothing in the tracked Start All set is running, but something outside it is
    /// (e.g. an Other commands / excluded-group process) — easy to forget is still on.
    case other
    /// Everything is stopped.
    case stopped
}
