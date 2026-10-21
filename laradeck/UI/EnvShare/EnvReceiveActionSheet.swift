import SwiftUI

/// First step after a LAN receive: Save (no local .env), or Overwrite / Merge when one exists.
struct EnvReceiveActionSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let payload: IncomingEnvPayload

    @State private var writeError: String?

    private var localExists: Bool {
        EnvFileIO.exists(at: payload.projectPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "envelope.open.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shared .env received")
                        .font(.title2.bold())
                    Text(payload.projectName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if localExists {
                Text("This project already has a .env. Overwrite it entirely, or merge key by key.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                NoticeBanner(
                    tone: .warning,
                    message: "Overwrite replaces the whole file. A backup is saved first."
                )
            } else {
                Text("This project has no .env yet. Save the shared file to get started.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let writeError {
                Text(writeError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Cancel") {
                    appState.pendingEnvReceive = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if localExists {
                    Button("Overwrite") {
                        writeIncoming(backupExisting: true)
                    }
                    Button("Merge…") {
                        openMergeEditor()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Save .env") {
                        writeIncoming(backupExisting: false)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 440, height: localExists ? 280 : 220)
    }

    private func writeIncoming(backupExisting: Bool) {
        writeError = nil
        do {
            try EnvFileIO.write(
                payload.incomingContents,
                to: payload.projectPath,
                backupExisting: backupExisting
            )
            appState.pendingEnvReceive = nil
            dismiss()
        } catch {
            writeError = error.localizedDescription
        }
    }

    private func openMergeEditor() {
        guard var pending = appState.pendingEnvReceive, pending.id == payload.id else { return }
        pending.phase = .mergeEditor
        appState.pendingEnvReceive = pending
        dismiss()
    }
}
