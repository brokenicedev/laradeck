import Foundation

/// A user-saved, reusable set of shell commands (spec §19), e.g. "Laravel Clear Everything".
nonisolated struct CommandPreset: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var commands: [String]
}
