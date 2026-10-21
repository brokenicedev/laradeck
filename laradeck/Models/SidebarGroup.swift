import Foundation

/// A user-defined bucket for organizing the sidebar's project list into collapsible sections.
/// Distinct from `ProcessGroup`, which groups processes *within* a project.
nonisolated struct SidebarGroup: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var isExpanded: Bool = true
}
