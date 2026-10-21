import Foundation
import UniformTypeIdentifiers
import CoreTransferable

extension UTType {
    /// In-app startup-sequence row drag. Kept distinct from file URLs so the
    /// main window's “drop folder to add project” handler never lights up.
    static var laradeckSequenceDrag: UTType {
        UTType(exportedAs: "it.brokenice.laradeck.sequence-drag")
    }
}

/// Payload for process / pause row drag within a sequence list.
struct LaradeckSequenceDragItem: Codable, Transferable, Hashable {
    var scope: String
    var rowId: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .laradeckSequenceDrag)
    }
}

/// Marks an in-app sequence drag so unrelated drop destinations (project folders) stay quiet.
@MainActor
enum InAppSequenceDrag {
    private(set) static var isActive = false

    static func begin() {
        isActive = true
    }

    static func end() {
        isActive = false
    }
}

/// Builds an NSItemProvider that only exposes our custom sequence UTI (never plain text / file URL).
enum SequenceDragPasteboard {
    static func itemProvider(scope: String, rowId: UUID) -> NSItemProvider {
        let item = LaradeckSequenceDragItem(scope: scope, rowId: rowId)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.laradeckSequenceDrag.identifier,
            visibility: .all
        ) { completion in
            do {
                completion(try JSONEncoder().encode(item), nil)
            } catch {
                completion(nil, error)
            }
            return nil
        }
        return provider
    }
}
