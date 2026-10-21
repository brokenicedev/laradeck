import DBEngineKit
import SwiftUI

/// Dashboard card for a native project: the local database servers its `.env` points at,
/// whether Laradeck runs them, and a shortcut to create the missing ones.
struct ProjectDatabasesView: View {
    @Environment(AppState.self) private var appState
    let project: Project
    let requirements: [ProjectDatabaseRequirement]

    @State private var creating: ProjectDatabaseRequirement?

    private var databases: DatabaseManager { appState.databaseManager }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Databases")
                    .font(.headline)
                Spacer()
                Button("Manage…") { appState.showingDatabases = true }
                    .buttonStyle(.link)
                    .font(.callout)
            }

            VStack(spacing: 0) {
                ForEach(requirements, id: \.self) { requirement in
                    requirementRow(requirement)
                    if requirement != requirements.last {
                        Divider().padding(.leading, 42)
                    }
                }
            }
            .laradeckCard()
        }
        .sheet(item: $creating) { requirement in
            NewDatabaseSheet(initialKind: requirement.kind, initialPort: requirement.port)
        }
    }

    @ViewBuilder
    private func requirementRow(_ requirement: ProjectDatabaseRequirement) -> some View {
        let service = ProjectDatabaseLink.service(for: requirement, in: databases.rows.map(\.service))
        let row = service.flatMap { databases.row(id: $0.id) }

        HStack(spacing: 12) {
            Image(systemName: "cylinder.split.1x2.fill")
                .font(.system(size: 18))
                .foregroundStyle(requirement.kind.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row?.service.name ?? requirement.kind.displayName)
                        .font(.body.weight(.medium))
                    PortBadgeView(ports: [requirement.port])
                }
                Text(detail(requirement, row: row))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let row, let database = requirement.database {
                    DatabaseNameBadge(name: database, service: row.service)
                        .padding(.top, 2)
                }
            }

            Spacer()

            if let row {
                if databases.busy.contains(row.id) {
                    ProgressView().controlSize(.small)
                }
                StatusDotView(color: row.status.color, size: 8)
                Button(row.status == .stopped ? "Start" : "Stop") {
                    databases.toggle(row)
                }
                .buttonStyle(.laradeckOutline(compact: true))
                .disabled(databases.busy.contains(row.id))
                Button {
                    appState.selectedDatabaseId = row.id
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.laradeckIcon())
                .help("Show \(row.service.name)")
            } else {
                Button("Create…") { creating = requirement }
                    .buttonStyle(.laradeckOutline(compact: true))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func detail(_ requirement: ProjectDatabaseRequirement, row: DatabaseManager.Row?) -> String {
        guard let row else {
            return "No Laradeck database on port \(requirement.port) (\(requirement.envKey) in .env)"
        }
        let start = row.isRunning ? "" : " · Start All will offer to start it"
        return "\(row.status.label) · \(requirement.kind.displayName) \(row.service.version)\(start)"
    }
}

extension ProjectDatabaseRequirement: Identifiable {
    var id: Self { self }
}
