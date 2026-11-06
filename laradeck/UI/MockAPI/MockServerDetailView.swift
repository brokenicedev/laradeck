import AppKit
import MockAPIKit
import SwiftUI

/// Detail page of a mock API server: routes, request log and settings.
struct MockServerDetailView: View {
    @Environment(AppState.self) private var appState
    let serverId: UUID

    enum Tab: String, CaseIterable {
        case routes = "Routes"
        case log = "Log"
        case settings = "Settings"
    }

    @State private var tab: Tab = .routes
    @State private var selectedRouteId: UUID?
    @State private var confirmingDelete = false

    private var service: MockAPIService { appState.mockAPIService }

    var body: some View {
        if let server = service.server(id: serverId) {
            content(server)
        } else {
            ContentUnavailableView("Mock API not found", systemImage: "questionmark")
        }
    }

    private func content(_ initial: MockServer) -> some View {
        let binding = Binding<MockServer>(
            get: { service.server(id: serverId) ?? initial },
            set: { service.update($0) }
        )
        let server = binding.wrappedValue
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header(server)
                if let message = service.state(serverId).failureMessage {
                    NoticeBanner(tone: .error, message: "Port \(server.port): \(message)")
                }
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        if tab == .log, let count = service.unmatchedCount[serverId], count > 0 {
                            Text("Log (\(count))").tag(tab)
                        } else {
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            switch tab {
            case .routes:
                MockRoutesView(server: binding, selectedRouteId: $selectedRouteId)
            case .log:
                MockLogView(serverId: serverId) { routeId in
                    selectedRouteId = routeId
                    tab = .routes
                }
            case .settings:
                MockServerSettingsView(server: binding)
            }
        }
        .background(LaradeckTheme.pageBackground)
        .laradeckTitle(server.name)
        .detailCloseButton(help: "Close mock API") { appState.selectedMockServerId = nil }
        .confirmationDialog("Delete “\(server.name)”?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                appState.selectedMockServerId = nil
                service.delete(serverId)
            }
        } message: {
            Text("Its routes and responses are removed. Export it first to keep a copy.")
        }
    }

    private func header(_ server: MockServer) -> some View {
        let state = service.state(serverId)
        let running = service.isRunning(serverId)
        let url = service.baseURL(for: server)
        return HStack(spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.teal)
                .frame(width: 44, height: 44)
                .background(Color.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(server.name)
                    .font(.title.weight(.semibold))
                HStack(spacing: 6) {
                    StatusDotView(color: state.dotColor, size: 8, pulsing: state.isStarting)
                    Text(statusText(state)).foregroundStyle(.secondary)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    } label: {
                        HStack(spacing: 3) {
                            Text(url)
                            Image(systemName: "doc.on.doc").font(.caption2)
                        }
                        .font(.callout.monospaced())
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Copy base URL")
                }
            }

            Spacer()

            Button {
                service.toggle(serverId)
            } label: {
                Label(running ? "Stop" : "Start", systemImage: running ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.laradeckOutline(accent: running ? .red : .green))

            Menu {
                MockServerMenuItems(server: server, onDelete: { confirmingDelete = true })
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func statusText(_ state: HTTPServer.State) -> String {
        switch state {
        case .running: return "Running"
        case .starting: return "Starting…"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }
}

/// Name, port, prefix, delay, CORS, global headers and the optional project link.
struct MockServerSettingsView: View {
    @Environment(AppState.self) private var appState
    @Binding var server: MockServer
    @State private var portText = ""
    @State private var portError: String?

    private var service: MockAPIService { appState.mockAPIService }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    row("Name") {
                        TextField("Name", text: $server.name)
                            .textFieldStyle(.roundedBorder)
                    }
                    row("Port", subtitle: portError) {
                        HStack {
                            TextField("Port", text: $portText)
                                .textFieldStyle(.roundedBorder)
                                .font(.body.monospacedDigit())
                                .frame(width: 90)
                                .onSubmit(applyPort)
                            Button("Apply", action: applyPort)
                                .disabled(Int(portText) == server.port)
                        }
                    }
                    row("Path prefix", subtitle: "Shared by every route, e.g. api/v1") {
                        TextField("api/v1", text: $server.prefix)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                    }
                    row("Delay", subtitle: "Added to every response") {
                        HStack {
                            TextField("0", value: $server.latencyMs, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                            Text("ms").foregroundStyle(.secondary)
                        }
                    }
                    row("CORS", subtitle: "Allow browsers on any origin and answer preflight requests") {
                        Toggle("CORS", isOn: $server.cors).toggleStyle(.switch).labelsHidden()
                    }
                    row("Start with Laradeck") {
                        Toggle("Start with Laradeck", isOn: $server.autoStart).toggleStyle(.switch).labelsHidden()
                    }
                }
                .padding(14)
                .laradeckCard()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Headers on every response").font(.headline)
                    Text("A route's own headers win over these.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HeaderListEditor(headers: $server.headers)
                }
                .padding(14)
                .laradeckCard()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Project").font(.headline)
                    Picker("Linked project", selection: $server.projectId) {
                        Text("None").tag(UUID?.none)
                        ForEach(appState.projects) { project in
                            Text(project.name).tag(UUID?.some(project.id))
                        }
                    }
                    .frame(maxWidth: 360)
                    HStack(alignment: .top) {
                        Text(envSnippet)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(envSnippet, forType: .string)
                        }
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    Text("Paste it in the project's .env and point your HTTP client at it. From Sail containers use host.docker.internal instead of 127.0.0.1.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .laradeckCard()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Notes").font(.headline)
                    TextEditor(text: $server.notes)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 80)
                    if let source = server.source {
                        Text("Imported from \(source)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .laradeckCard()
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { portText = String(server.port) }
        .onChange(of: server.port) { portText = String(server.port) }
    }

    private var envSnippet: String {
        let key = server.name.uppercased()
            .replacingOccurrences(of: "[^A-Z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return "\(key.isEmpty ? "MOCK" : key)_URL=\(service.baseURL(for: server))"
    }

    private func applyPort() {
        guard let port = Int(portText), (1...65535).contains(port) else {
            portError = "Enter a port between 1 and 65535."
            return
        }
        guard port != server.port else { portError = nil; return }
        if let other = service.servers.first(where: { $0.id != server.id && $0.port == port }) {
            portError = "“\(other.name)” already uses port \(port)."
            return
        }
        if PortConflictService.isPortInUse(port) {
            portError = "Port \(port) is in use by another app. Try \(service.freePort(preferred: port, excluding: server.id))."
            return
        }
        portError = nil
        server.port = port
    }

    private func row<Content: View>(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(title == "Port" ? .red : .secondary)
                }
            }
            .frame(width: 200, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}
