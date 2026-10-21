import AppKit
import SwiftUI

/// Warns before Compose Up / Start All when host ports are already taken.
struct PortConflictSheet: View {
    let report: PortConflictReport
    let intent: PortConflictIntent
    var onCancel: () -> Void
    var onContinue: () -> Void

    @State private var didCopy = false

    private var continueTitle: String {
        switch intent {
        case .composeUp: return "Start Anyway"
        case .startAll: return "Start All Anyway"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Port conflicts")
                        .font(.title3.weight(.semibold))
                    Text(report.projectName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Another process or project is already using ports that \(report.projectName) needs. Change the values in `.env` (or stop the other stack), then try again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(report.conflicts) { conflict in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: ":\(conflict.port)")
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .frame(width: 64, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conflict.requirement.label)
                                .font(.callout.weight(.medium))
                            Text(conflict.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if conflict.requirement.isEnvWritable {
                            Text(verbatim: conflict.requirement.key)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                    if conflict.id != report.conflicts.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 12)
            .laradeckCard(cornerRadius: 8)

            if !report.suggestedEnvSnippet.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Suggested `.env` overrides")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(verbatim: report.suggestedEnvSnippet)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.quaternary, lineWidth: 1)
                        }

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.suggestedEnvSnippet, forType: .string)
                        didCopy = true
                    } label: {
                        Label(didCopy ? "Copied" : "Copy to Clipboard", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.laradeckOutline)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(continueTitle, action: onContinue)
                    .buttonStyle(.laradeckOutline(accent: .orange))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
