import SwiftUI

/// Key-by-key merge UI after choosing Merge on the receive action sheet.
struct EnvReceiveReviewView: View {
    @Environment(AppState.self) private var appState

    let payload: IncomingEnvPayload
    var onFinished: () -> Void

    @State private var rows: [EnvMergeRow] = []
    @State private var showUnchanged = false
    @State private var writeError: String?

    private var visibleRows: [EnvMergeRow] {
        rows.filter { showUnchanged || $0.kind != .identical }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Pick local or incoming values for each key, then apply the merge.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    mergeToolbar
                    mergeList

                    if let writeError {
                        Text(writeError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
            }

            Divider()

            HStack {
                Button("Cancel", role: .cancel, action: onFinished)
                Spacer()
                Button("Apply Merge") {
                    apply()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LaradeckTheme.pageBackground)
        .onAppear {
            let local = EnvFileIO.read(at: payload.projectPath).map(EnvFileCodec.parse) ?? []
            let incoming = EnvFileCodec.parse(payload.incomingContents)
            rows = EnvMergeDiff.rows(local: local, incoming: incoming)
            if appState.selectedProjectId != payload.projectId {
                appState.selectedProjectId = payload.projectId
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            if let project = appState.project(withId: payload.projectId) {
                ProjectFaviconView(project: project, size: 40)
            } else {
                EnvSharePeerAvatarProxy(name: payload.projectName, size: 40)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Merge shared .env")
                    .font(.title2.bold())
                Text(payload.projectName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var mergeToolbar: some View {
        HStack {
            Button("Accept all incoming") {
                for index in rows.indices where rows[index].kind != .identical {
                    if rows[index].incomingValue != nil {
                        rows[index].choice = .takeIncoming
                    }
                }
            }
            .buttonStyle(.laradeckOutline)
            Button("Keep all local") {
                for index in rows.indices where rows[index].kind != .identical {
                    if rows[index].localValue != nil {
                        rows[index].choice = .keepLocal
                    } else {
                        rows[index].choice = .drop
                    }
                }
            }
            .buttonStyle(.laradeckOutline)
            Toggle("Show unchanged", isOn: $showUnchanged)
            Spacer()
        }
        .controlSize(.small)
    }

    private var mergeList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(visibleRows.enumerated()), id: \.element.id) { _, row in
                mergeRow(row)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .laradeckCard(cornerRadius: 10)
            }
        }
    }

    @ViewBuilder
    private func mergeRow(_ row: EnvMergeRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.key)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                Spacer()
                Text(kindLabel(row.kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if row.kind == .conflict {
                HStack(alignment: .top, spacing: 12) {
                    valueColumn(title: "Local", value: row.localValue ?? "", selected: row.choice == .keepLocal) {
                        updateChoice(for: row.key, to: .keepLocal)
                    }
                    valueColumn(title: "Incoming", value: row.incomingValue ?? "", selected: row.choice == .takeIncoming) {
                        updateChoice(for: row.key, to: .takeIncoming)
                    }
                }
            } else if row.kind == .onlyIncoming {
                Toggle("Add incoming value", isOn: Binding(
                    get: { row.choice == .takeIncoming },
                    set: { updateChoice(for: row.key, to: $0 ? .takeIncoming : .drop) }
                ))
                Text(masked(row.incomingValue ?? ""))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else if row.kind == .onlyLocal {
                Toggle("Keep local value", isOn: Binding(
                    get: { row.choice == .keepLocal },
                    set: { updateChoice(for: row.key, to: $0 ? .keepLocal : .drop) }
                ))
                Text(masked(row.localValue ?? ""))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Text(masked(row.localValue ?? row.incomingValue ?? ""))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func valueColumn(title: String, value: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(masked(value))
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
    }

    private func kindLabel(_ kind: EnvMergeKind) -> String {
        switch kind {
        case .onlyLocal: return "Only local"
        case .onlyIncoming: return "Only incoming"
        case .conflict: return "Different"
        case .identical: return "Unchanged"
        }
    }

    private func masked(_ value: String) -> String {
        value
    }

    private func updateChoice(for key: String, to choice: EnvMergeChoice) {
        guard let index = rows.firstIndex(where: { $0.key == key }) else { return }
        rows[index].choice = choice
    }

    private func apply() {
        writeError = nil
        do {
            let contents = EnvFileCodec.serialize(EnvMergeDiff.apply(rows))
            try EnvFileIO.write(contents, to: payload.projectPath, backupExisting: true)
            onFinished()
        } catch {
            writeError = error.localizedDescription
        }
    }
}

/// Lightweight initials avatar when the target project isn't in AppState yet.
private struct EnvSharePeerAvatarProxy: View {
    let name: String
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(Color(hex: ProjectColorPalette.defaultHex(for: name)))
            Text(ProjectFaviconView.initials(for: name))
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}
