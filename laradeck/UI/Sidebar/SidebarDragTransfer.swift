import Foundation
import UniformTypeIdentifiers
import CoreTransferable

extension UTType {
    /// In-app sidebar project drag — kept distinct from file URLs so it's never mistaken
    /// for a dropped folder by the main window's "drop to add project" handler.
    static var laradeckSidebarProjectDrag: UTType {
        UTType(exportedAs: "it.brokenice.laradeck.sidebar-project-drag")
    }
}

/// Payload for dragging a project row onto a sidebar group.
struct SidebarProjectDragItem: Codable, Transferable, Hashable {
    var projectId: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .laradeckSidebarProjectDrag)
    }
}

extension UTType {
    /// In-app sidebar group reorder drag (distinct from the project drag above).
    static var laradeckSidebarGroupDrag: UTType {
        UTType(exportedAs: "it.brokenice.laradeck.sidebar-group-drag")
    }
}

/// Payload for dragging a group header to reorder the sidebar's group list.
struct SidebarGroupDragItem: Codable, Transferable, Hashable {
    var groupId: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .laradeckSidebarGroupDrag)
    }
}
