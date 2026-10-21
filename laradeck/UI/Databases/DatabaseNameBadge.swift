import DBEngineKit
import SwiftUI

/// A project's `DB_DATABASE` on a server: found, missing (with Create), or unknown while stopped.
struct DatabaseNameBadge: View {
    @Environment(AppState.self) private var appState
    let name: String
    let service: Service

    private var databases: DatabaseManager { appState.databaseManager }
    private var isRunning: Bool { databases.row(id: service.id)?.isRunning == true }

    var body: some View {
        let check = databases.check(database: name, in: service)
        HStack(spacing: 6) {
            switch check {
            case .exists:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(name).font(.callout.monospaced())
            case .missing:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(name).font(.callout.monospaced())
                Text("doesn't exist")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Create") { databases.createDatabase(name, in: service) }
                    .buttonStyle(.laradeckOutline(accent: .orange, compact: true))
                    .disabled(databases.busy.contains(service.id))
            case .unknown:
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .help(helpText(check))
        // Ask the server again whenever it starts or stops.
        .task(id: isRunning) {
            await databases.loadDatabaseNames(service)
        }
    }

    private func helpText(_ check: DatabaseManager.DatabaseCheck) -> String {
        switch check {
        case .exists: return "DB_DATABASE=\(name) exists on \(service.name)"
        case .missing: return "DB_DATABASE=\(name) isn't on \(service.name). Create it, or run php artisan migrate."
        case .unknown: return "Start \(service.name) to check that \(name) exists"
        }
    }
}
