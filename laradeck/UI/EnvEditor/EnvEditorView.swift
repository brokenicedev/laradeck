import SwiftUI
import AppKit

/// In-app replacement for opening `.env` in a text editor: a proper table, with masked secrets
/// and file import/export.
struct EnvEditorView: View {
    let project: Project
    let onDone: () -> Void

    @State private var rows: [EnvVariable] = []
    @State private var hasLoaded = false
    @State private var showingShare = false
    @State private var showingReceive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Table(rows) {
                TableColumn("Key") { row in
                    TextField("KEY_NAME", text: binding(for: row.id).key)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                }
                .width(min: 140, ideal: 220)

                TableColumn("Value") { row in
                    valueField(for: row)
                }
                .width(min: 200, ideal: 340)

                TableColumn("") { row in
                    Button {
                        rows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                .width(28)
            }
            .laradeckCard(cornerRadius: 8)

            HStack {
                Button {
                    rows.append(EnvVariable(key: "", value: ""))
                } label: {
                    Label("Add Variable", systemImage: "plus")
                }
                .buttonStyle(.laradeckOutline)
                Button {
                    importFromFile()
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.laradeckOutline)
                Button {
                    exportToFile()
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.laradeckOutline)
                Button {
                    showingShare = true
                } label: {
                    Label("Share on LAN…", systemImage: "wifi")
                }
                .buttonStyle(.laradeckOutline)
                Button {
                    showingReceive = true
                } label: {
                    Label("Receive…", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.laradeckOutline)
                Spacer()
                Button("Cancel") { onDone() }
                Button {
                    save()
                } label: {
                    Label("Save", systemImage: "checkmark")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LaradeckTheme.pageBackground)
        .navigationTitle(".env — \(project.name)")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    onDone()
                } label: {
                    Label("Dashboard", systemImage: "chevron.left")
                }
            }
        }
        .task(id: project.path) {
            guard !hasLoaded else { return }
            hasLoaded = true
            load()
        }
        .sheet(isPresented: $showingShare) {
            EnvShareHostView(project: project)
        }
        .sheet(isPresented: $showingReceive) {
            EnvReceiveView()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(".env — \(project.name)")
                .font(.title2.bold())
            PathLinkButton(path: project.path, lineLimit: 1)
            Text("Saving rewrites .env as KEY=VALUE pairs — comments and custom formatting in the original file aren't preserved.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func valueField(for row: EnvVariable) -> some View {
        let valueBinding = binding(for: row.id).value
        let sensitive = EnvFileCodec.isSensitive(row.key)
        let revealed = row.isRevealed

        HStack(spacing: 4) {
            Group {
                if sensitive, !revealed {
                    // Bullets instead of SecureField — swapping SecureField→TextField in a Table
                    // cell often shows an empty field on macOS even when the binding has a value.
                    Text(row.value.isEmpty ? "—" : String(repeating: "•", count: min(max(row.value.count, 6), 24)))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                } else {
                    TextField("value", text: valueBinding)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .id("\(row.id.uuidString)-revealed-\(revealed)")

            if sensitive {
                Button {
                    toggleReveal(for: row.id)
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(revealed ? "Hide value" : "Show value")
            }
        }
    }

    private func toggleReveal(for id: EnvVariable.ID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].isRevealed.toggle()
    }

    private func binding(for id: EnvVariable.ID) -> Binding<EnvVariable> {
        Binding(
            get: { rows.first { $0.id == id } ?? EnvVariable(key: "", value: "") },
            set: { newValue in
                guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
                rows[index] = newValue
            }
        )
    }

    private var envFileURL: URL {
        project.directoryURL.appendingPathComponent(".env")
    }

    private func load() {
        guard let contents = try? String(contentsOf: envFileURL, encoding: .utf8) else { return }
        rows = EnvFileCodec.parse(contents)
    }

    private func save() {
        let cleanRows = rows.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
        let contents = EnvFileCodec.serialize(cleanRows)
        try? contents.write(to: envFileURL, atomically: true, encoding: .utf8)
        onDone()
    }

    private func exportToFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ".env"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let cleanRows = rows.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
        let contents = EnvFileCodec.serialize(cleanRows)
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return }

        for imported in EnvFileCodec.parse(contents) {
            if let index = rows.firstIndex(where: { $0.key == imported.key }) {
                rows[index].value = imported.value
                rows[index].quote = imported.quote
            } else {
                rows.append(imported)
            }
        }
    }
}
