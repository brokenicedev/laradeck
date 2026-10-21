import SwiftUI

/// Creates and edits global command presets — opened from Add Process.
struct CommandPresetsManagerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var editingPreset: CommandPreset?
    @State private var draftName = ""
    @State private var draftCommands = ""

    var body: some View {
        @Bindable var appState = appState

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Command Presets")
                    .font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }

            Text("Saved command bundles you can pick when adding a process to a project.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(appState.presets) { preset in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preset.name)
                            .font(.body.weight(.medium))
                        Text(preset.commands.joined(separator: " · "))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .contextMenu {
                        Button("Edit") { beginEdit(preset) }
                        Button("Delete", role: .destructive) { delete(preset) }
                    }
                }
                .onDelete { indexSet in
                    appState.presets.remove(atOffsets: indexSet)
                }
            }

            Button("Add Preset") { beginAdd() }
        }
        .padding(20)
        .frame(width: 480, height: 420)
        .sheet(item: $editingPreset) { _ in
            presetEditorSheet
        }
    }

    private var presetEditorSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editingPreset?.name.isEmpty == false && appState.presets.contains(where: { $0.id == editingPreset?.id }) ? "Edit Preset" : "New Preset")
                .font(.title2.bold())

            Form {
                TextField("Name", text: $draftName)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Commands")
                    TextEditor(text: $draftCommands)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 120)
                    Text("One command per line, e.g. php artisan migrate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Cancel") { editingPreset = nil }
                Spacer()
                Button("Save") { savePreset() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440, height: 320)
    }

    private func beginAdd() {
        editingPreset = CommandPreset(name: "", commands: [])
        draftName = ""
        draftCommands = ""
    }

    private func beginEdit(_ preset: CommandPreset) {
        editingPreset = preset
        draftName = preset.name
        draftCommands = preset.commands.joined(separator: "\n")
    }

    private func savePreset() {
        let commands = draftCommands
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let editingPreset else { return }

        if let index = appState.presets.firstIndex(where: { $0.id == editingPreset.id }) {
            appState.presets[index].name = draftName.trimmingCharacters(in: .whitespaces)
            appState.presets[index].commands = commands
        } else {
            appState.presets.append(
                CommandPreset(name: draftName.trimmingCharacters(in: .whitespaces), commands: commands)
            )
        }
        self.editingPreset = nil
    }

    private func delete(_ preset: CommandPreset) {
        appState.presets.removeAll { $0.id == preset.id }
    }
}
