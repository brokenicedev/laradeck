import SwiftUI

/// Lets the developer merge newly detected scripts/artisan/core processes into an existing project.
struct RefreshCommandsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let project: Project

    @State private var commands: [RediscoveredCommand] = []
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            Group {
                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Scanning project…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if commands.isEmpty {
                    ContentUnavailableView(
                        "Nothing New",
                        systemImage: "checkmark.circle",
                        description: Text("All detected commands are already in this project.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    commandsList
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()
            footer.padding(20)
        }
        .frame(width: 580, height: 520)
        .task {
            isLoading = true
            defer { isLoading = false }
            commands = await ProcessRediscovery.discoverNew(for: project)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 20))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text("Refresh Commands")
                    .font(.title2.bold())
                Text(project.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var commandsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New commands found in your project — add what you need.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach($commands) { $item in
                        commandRow($item)
                        if item.id != commands.last?.id {
                            Divider().padding(.leading, 36)
                        }
                    }
                }
            }
            .laradeckCard(cornerRadius: 10)
        }
    }

    private func commandRow(_ item: Binding<RediscoveredCommand>) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: item.isIncluded)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.wrappedValue.title)
                        .font(item.wrappedValue.source == .artisan ? .body.weight(.medium).monospaced() : .body.weight(.medium))
                    Text(item.wrappedValue.sourceBadge)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }
                if !item.wrappedValue.subtitle.isEmpty, item.wrappedValue.source != .script {
                    Text(item.wrappedValue.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(item.wrappedValue.preview)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if item.wrappedValue.isIncluded, item.wrappedValue.source != .core {
                MenuPicker(
                    selection: Binding(
                        get: { item.wrappedValue.useOtherCommandsGroup },
                        set: { item.wrappedValue.useOtherCommandsGroup = $0 }
                    ),
                    width: 150,
                    options: [
                        (false, "Processes"),
                        (true, "Other commands"),
                    ]
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .opacity(item.wrappedValue.isIncluded ? 1 : 0.5)
    }

    private var footer: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Label("Cancel", systemImage: "xmark")
            }
            .buttonStyle(.laradeckOutline)
            Spacer()
            Button {
                apply()
            } label: {
                Label("Add Selected", systemImage: "plus")
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(isLoading || !commands.contains(where: \.isIncluded))
        }
    }

    private func apply() {
        var updated = project
        updated.ensureOtherCommandsGroup()
        let otherGroupId = updated.otherCommandsGroupId

        for item in commands where item.isIncluded {
            guard var definition = ProcessRediscovery.makeProcessDefinition(from: item, project: project) else { continue }
            if item.useOtherCommandsGroup, let otherGroupId, item.source != .core {
                definition.groupId = otherGroupId
            }
            updated.processes.append(definition)
        }

        appState.updateProject(updated)
        dismiss()
    }
}
