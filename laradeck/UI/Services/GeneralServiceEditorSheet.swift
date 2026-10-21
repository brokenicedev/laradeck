import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Add a general service from YAML (typed, pasted, chosen or dropped), or edit an existing one.
struct GeneralServiceEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// nil = new service.
    var editing: GeneralService?

    @State private var name = ""
    @State private var yaml = ""
    @State private var error: String?
    @State private var working = false
    @State private var isDropTargeted = false
    @State private var didAppear = false
    @State private var autoStart = true

    private var services: GeneralServicesManager { appState.generalServices }

    private static let example = """
    services:
      mailpit:
        image: axllent/mailpit
        restart: unless-stopped
        ports:
          - "1025:1025"   # SMTP
          - "8025:8025"   # Web UI
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editing == nil ? "New Service" : "Edit \(editing!.displayName)")
                .font(.title2.bold())

            Text("A Docker Compose file for a service shared by all your projects, like Mailpit or Gotenberg. Paste it, type it, or drop a .yaml file here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Name", text: $name, prompt: Text(Self.suggestedName(yaml) ?? "Name"))
                .textFieldStyle(.roundedBorder)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $yaml)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                if yaml.isEmpty {
                    Text(Self.example)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 260)
            .laradeckCard()
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: LaradeckTheme.cardCornerRadius)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                load(url)
                return true
            } isTargeted: { isDropTargeted = $0 }

            if editing == nil {
                Toggle("Start when Laradeck opens", isOn: $autoStart)
            }

            if let error {
                Text(error)
                    .font(.callout.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Choose File…", action: chooseFile)
                if working {
                    ProgressView().controlSize(.small)
                    Text("Checking with docker compose…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            if let editing {
                name = editing.name
                yaml = services.yaml(for: editing)
            }
        }
    }

    private static func suggestedName(_ yaml: String) -> String? {
        GeneralServicesManager.firstServiceName(in: yaml)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "yaml"), UTType(filenameExtension: "yml")].compactMap { $0 }
        panel.message = "Choose a Docker Compose file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    private func load(_ url: URL) {
        do {
            yaml = try String(contentsOf: url, encoding: .utf8)
            error = nil
            if name.isEmpty {
                let file = url.deletingPathExtension().lastPathComponent.lowercased()
                if !file.hasPrefix("docker-compose"), !file.hasPrefix("compose") {
                    name = url.deletingPathExtension().lastPathComponent
                }
            }
        } catch {
            self.error = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func save() {
        working = true
        error = nil
        Task {
            do {
                if let editing {
                    try await services.update(editing, name: name, yaml: yaml)
                } else {
                    let service = try await services.add(name: name, yaml: yaml, autoStart: autoStart)
                    appState.selectedServiceId = service.id
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
