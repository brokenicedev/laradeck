import MockAPIKit
import SwiftUI

/// Route list on the left, the selected route's editor on the right.
struct MockRoutesView: View {
    @Binding var server: MockServer
    @Binding var selectedRouteId: UUID?
    @State private var filter = ""

    var body: some View {
        HStack(spacing: 0) {
            routeList
                .frame(width: 280)
            Divider()
            if let binding = routeBinding(selectedRouteId) {
                MockRouteEditor(route: binding, prefix: server.prefix, onDelete: deleteSelected)
                    .id(selectedRouteId)
            } else {
                ContentUnavailableView {
                    Label("No Route Selected", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("Pick a route on the left, or add one.")
                } actions: {
                    Button("Add Route") { addRoute() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selectedRouteId == nil { selectedRouteId = server.routes.first?.id }
        }
    }

    private var visibleRoutes: [MockRoute] {
        guard !filter.isEmpty else { return server.routes }
        return server.routes.filter {
            $0.path.localizedCaseInsensitiveContains(filter)
                || $0.method.localizedCaseInsensitiveContains(filter)
                || $0.notes.localizedCaseInsensitiveContains(filter)
        }
    }

    private var routeList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Filter routes", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Button {
                    addRoute()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add route")
            }
            .padding(8)
            List(selection: $selectedRouteId) {
                ForEach(visibleRoutes) { route in
                    HStack(spacing: 6) {
                        MethodBadge(method: route.method, compact: true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("/" + route.path)
                                .font(.callout.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if !route.notes.isEmpty {
                                Text(route.notes)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if route.responses.count > 1 {
                            Text("\(route.responses.count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .help("\(route.responses.count) responses")
                        }
                    }
                    .opacity(route.enabled ? 1 : 0.45)
                    .tag(route.id)
                    .contextMenu {
                        Button(route.enabled ? "Disable" : "Enable") { toggle(route.id) }
                        Button("Duplicate") { duplicate(route.id) }
                        Divider()
                        Button("Delete", role: .destructive) { delete(route.id) }
                    }
                }
                .onMove { source, destination in
                    guard filter.isEmpty else { return }
                    server.routes.move(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.sidebar)
            .onDeleteCommand(perform: deleteSelected)
        }
    }

    private func routeBinding(_ id: UUID?) -> Binding<MockRoute>? {
        guard let id, let route = server.routes.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { server.routes.first { $0.id == id } ?? route },
            set: { newValue in
                guard let index = server.routes.firstIndex(where: { $0.id == id }) else { return }
                server.routes[index] = newValue
            }
        )
    }

    private func addRoute() {
        let route = MockRoute(method: "GET", path: "new-route", responses: [
            MockResponse(label: "OK", status: 200,
                         headers: [MockHeader(name: "Content-Type", value: "application/json")],
                         body: "{\n    \"ok\": true\n}", isDefault: true),
        ])
        server.routes.append(route)
        filter = ""
        selectedRouteId = route.id
    }

    private func toggle(_ id: UUID) {
        guard let index = server.routes.firstIndex(where: { $0.id == id }) else { return }
        server.routes[index].enabled.toggle()
    }

    private func duplicate(_ id: UUID) {
        guard let index = server.routes.firstIndex(where: { $0.id == id }) else { return }
        var copy = server.routes[index]
        copy.id = UUID()
        copy.responses = copy.responses.map { var r = $0; r.id = UUID(); return r }
        server.routes.insert(copy, at: index + 1)
        selectedRouteId = copy.id
    }

    private func delete(_ id: UUID) {
        guard let index = server.routes.firstIndex(where: { $0.id == id }) else { return }
        server.routes.remove(at: index)
        if selectedRouteId == id {
            selectedRouteId = server.routes.indices.contains(index) ? server.routes[index].id : server.routes.last?.id
        }
    }

    private func deleteSelected() {
        if let id = selectedRouteId { delete(id) }
    }
}

/// Method, path and responses of one route.
struct MockRouteEditor: View {
    @Binding var route: MockRoute
    let prefix: String
    let onDelete: () -> Void
    @State private var selectedResponseId: UUID?
    @State private var showingTemplateHelp = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                routeCard
                responsesCard
            }
            .padding(16)
        }
        .onAppear {
            if selectedResponseId == nil { selectedResponseId = route.defaultResponse?.id }
        }
    }

    private var routeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("Method", selection: $route.method) {
                    ForEach(MockRoute.methods, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 100)
                HStack(spacing: 0) {
                    Text(verbatim: PathPattern.join(prefix) == "/" ? "/" : PathPattern.join(prefix) + "/")
                        .foregroundStyle(.secondary)
                    TextField("users/:id", text: $route.path)
                        .textFieldStyle(.plain)
                }
                .font(.body.monospaced())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                Toggle("Enabled", isOn: $route.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete route")
            }
            TextField("Description", text: $route.notes)
                .textFieldStyle(.roundedBorder)
            Text("Use :name or {name} for parameters and * at the end to match anything below.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .laradeckCard()
    }

    private var responsesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Responses").font(.headline)
                Spacer()
                Picker("Mode", selection: $route.responseMode) {
                    Text("Rules").tag(ResponseMode.rules)
                    Text("Sequential").tag(ResponseMode.sequential)
                    Text("Random").tag(ResponseMode.random)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Rules: first response whose rules match, else the default. Sequential: one after another. Random: any.")
                Button {
                    showingTemplateHelp.toggle()
                } label: {
                    Image(systemName: "curlybraces")
                }
                .buttonStyle(.borderless)
                .help("Template tags")
                .popover(isPresented: $showingTemplateHelp) { TemplateHelpView() }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(route.responses) { response in
                        responseTab(response)
                    }
                    Button {
                        addResponse()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add response")
                }
            }

            if let index = route.responses.firstIndex(where: { $0.id == selectedResponseId }) {
                MockResponseEditor(
                    response: $route.responses[index],
                    usesRules: route.responseMode == .rules,
                    onMakeDefault: { makeDefault(route.responses[index].id) },
                    onDuplicate: { duplicateResponse(route.responses[index].id) },
                    onDelete: route.responses.count > 1 ? { deleteResponse(route.responses[index].id) } : nil
                )
                .id(selectedResponseId)
            }
        }
        .padding(14)
        .laradeckCard()
    }

    private func responseTab(_ response: MockResponse) -> some View {
        let selected = response.id == selectedResponseId
        return Button {
            selectedResponseId = response.id
        } label: {
            HStack(spacing: 5) {
                StatusBadge(status: response.status)
                Text(response.label.isEmpty ? "Response" : response.label)
                    .lineLimit(1)
                if response.isDefault && route.responseMode == .rules {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .help("Default response")
                }
                if !response.rules.isEmpty && route.responseMode == .rules {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("\(response.rules.count) rule(s)")
                }
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor.opacity(0.6) : .clear))
        }
        .buttonStyle(.plain)
    }

    private func addResponse() {
        let response = MockResponse(label: "", status: 200,
                                    headers: [MockHeader(name: "Content-Type", value: "application/json")],
                                    body: "{}", isDefault: route.responses.isEmpty)
        route.responses.append(response)
        selectedResponseId = response.id
    }

    private func makeDefault(_ id: UUID) {
        for index in route.responses.indices {
            route.responses[index].isDefault = route.responses[index].id == id
        }
    }

    private func duplicateResponse(_ id: UUID) {
        guard let index = route.responses.firstIndex(where: { $0.id == id }) else { return }
        var copy = route.responses[index]
        copy.id = UUID()
        copy.isDefault = false
        copy.label = copy.label.isEmpty ? "Copy" : "\(copy.label) copy"
        route.responses.insert(copy, at: index + 1)
        selectedResponseId = copy.id
    }

    private func deleteResponse(_ id: UUID) {
        guard let index = route.responses.firstIndex(where: { $0.id == id }) else { return }
        let wasDefault = route.responses[index].isDefault
        route.responses.remove(at: index)
        if wasDefault, !route.responses.isEmpty { route.responses[0].isDefault = true }
        selectedResponseId = route.responses[min(index, route.responses.count - 1)].id
    }
}

/// Status, headers, rules and body of one response.
struct MockResponseEditor: View {
    @Binding var response: MockResponse
    let usesRules: Bool
    let onMakeDefault: () -> Void
    let onDuplicate: () -> Void
    let onDelete: (() -> Void)?

    static let commonStatuses = [200, 201, 202, 204, 301, 302, 304, 400, 401, 403, 404, 405, 409, 422, 429, 500, 502, 503]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                TextField("Status", value: $response.status, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospacedDigit())
                    .frame(width: 60)
                Menu {
                    ForEach(Self.commonStatuses, id: \.self) { code in
                        Button("\(code) \(HTTPResponse.reason(code))") { response.status = code }
                    }
                } label: {
                    Text(HTTPResponse.reason(response.status))
                }
                .fixedSize()
                TextField("Label", text: $response.label)
                    .textFieldStyle(.roundedBorder)
                TextField("Delay", value: $response.latencyMs, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .help("Extra delay for this response, in milliseconds")
                Text("ms").foregroundStyle(.secondary)
                Menu {
                    if usesRules {
                        Button("Make Default", action: onMakeDefault)
                            .disabled(response.isDefault)
                    }
                    Button("Duplicate", action: onDuplicate)
                    if let onDelete {
                        Divider()
                        Button("Delete", role: .destructive, action: onDelete)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if usesRules {
                section("Rules", subtitle: response.isDefault
                        ? "Default response: used when no other response's rules match."
                        : "Used when these rules match the request.") {
                    RuleListEditor(rules: $response.rules, rulesOperator: $response.rulesOperator)
                }
            }

            section("Headers") {
                HeaderListEditor(headers: $response.headers)
            }

            section("Body") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Templating ({{…}} tags are rendered)", isOn: $response.templating)
                        .toggleStyle(.checkbox)
                        .font(.callout)
                    BodyEditor(text: $response.body, contentType: contentType)
                        .frame(minHeight: 220)
                }
            }
        }
    }

    private var contentType: String? {
        response.headers.first { $0.name.lowercased() == "content-type" }?.value
    }

    private func section<Content: View>(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            content()
        }
    }
}
