import MockAPIKit
import SwiftUI

/// Requests a mock server received, newest first, with request/response details.
struct MockLogView: View {
    @Environment(AppState.self) private var appState
    let serverId: UUID
    let onShowRoute: (UUID) -> Void
    @State private var selectedId: UUID?
    @State private var onlyUnmatched = false

    private var service: MockAPIService { appState.mockAPIService }

    private var entries: [MockLogEntry] {
        let all = service.logs[serverId] ?? []
        return onlyUnmatched ? all.filter { !$0.matched } : all
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Toggle("Only unmatched", isOn: $onlyUnmatched)
                        .toggleStyle(.checkbox)
                    Spacer()
                    Button("Clear") {
                        service.clearLog(serverId)
                        selectedId = nil
                    }
                    .disabled((service.logs[serverId] ?? []).isEmpty)
                }
                .font(.callout)
                .padding(8)
                if entries.isEmpty {
                    ContentUnavailableView("No Requests Yet", systemImage: "tray",
                                           description: Text("Requests to this mock show up here."))
                        .frame(maxHeight: .infinity)
                } else {
                    List(entries, selection: $selectedId) { entry in
                        row(entry).tag(entry.id)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 320, idealWidth: 380)
            Divider()
            if let entry = entries.first(where: { $0.id == selectedId }) ?? (service.logs[serverId] ?? []).first(where: { $0.id == selectedId }) {
                detail(entry)
            } else {
                ContentUnavailableView("Select a Request", systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { service.markLogSeen(serverId) }
        .onChange(of: service.logs[serverId]?.first?.id) { service.markLogSeen(serverId) }
    }

    private func row(_ entry: MockLogEntry) -> some View {
        HStack(spacing: 6) {
            MethodBadge(method: entry.method, compact: true)
            Text(entry.fullPath)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if !entry.matched {
                Image(systemName: "questionmark.diamond")
                    .foregroundStyle(.orange)
                    .help("No route matched")
            }
            StatusBadge(status: entry.status)
            Text(entry.date, format: .dateTime.hour().minute().second())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func detail(_ entry: MockLogEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    MethodBadge(method: entry.method)
                    Text(entry.fullPath).font(.body.monospaced()).textSelection(.enabled)
                    Spacer()
                    StatusBadge(status: entry.status)
                    Text("\(entry.durationMs) ms").font(.caption).foregroundStyle(.secondary)
                }
                if let routeId = entry.routeId {
                    HStack {
                        Text("Answered by \(entry.responseLabel ?? "a response")")
                            .foregroundStyle(.secondary)
                        Button("Show Route") { onShowRoute(routeId) }
                            .buttonStyle(.link)
                    }
                    .font(.callout)
                } else {
                    HStack {
                        Text("No route matched this request.")
                            .foregroundStyle(.orange)
                        Button("Create Route") {
                            if let route = service.addRoute(from: entry, to: serverId) { onShowRoute(route.id) }
                        }
                    }
                    .font(.callout)
                }
                block("Request headers", text: entry.requestHeaders.sorted { $0.key < $1.key }
                    .map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
                if !entry.requestBody.isEmpty { block("Request body", text: pretty(entry.requestBody)) }
                block("Response headers", text: entry.responseHeaders.map { "\($0.name): \($0.value)" }.joined(separator: "\n"))
                if !entry.responseBody.isEmpty { block("Response body", text: pretty(entry.responseBody)) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func block(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text.isEmpty ? "—" : text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .laradeckCard()
        }
    }

    private func pretty(_ text: String) -> String {
        (try? JSONValue.parse(text)).map { $0.serialized(pretty: true) } ?? text
    }
}
