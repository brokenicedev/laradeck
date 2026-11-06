import SwiftUI

/// Settings → Mock APIs: launch behavior and log size.
struct MockAPISettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var service = appState.mockAPIService

        Form {
            Section {
                Toggle("Start mock APIs marked “Start with Laradeck”", isOn: $service.autoStartEnabled)
                Picker("Keep in the log", selection: $service.logLimit) {
                    ForEach([100, 500, 1000, 5000], id: \.self) { Text("\($0) requests").tag($0) }
                }
            } header: {
                Text("Servers")
            } footer: {
                Text("Each mock API has its own port, routes and settings on its page in the sidebar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add a mock from the + menu next to Mock APIs in the sidebar, or drop a file on the main window:")
                    Text("• OpenAPI 3 / Swagger 2 (JSON or YAML): examples become responses, schemas generate sample bodies.")
                    Text("• Postman collections v2.x: every saved example becomes a response.")
                    Text("• Laradeck mock exports (.laradeck-mock.json).")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            } header: {
                Text("Import")
            }
        }
        .formStyle(.grouped)
    }
}
