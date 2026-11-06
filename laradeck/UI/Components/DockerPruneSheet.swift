import AppKit
import SwiftUI

/// Docker cleanup sheet, opened from the toolbar popover: shows what will be removed, asks to
/// confirm, then follows the prune live and reports how much space it freed.
struct DockerPruneSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let kind: DockerPruneKind

    private enum Phase {
        case loading
        case preview(DockerPrunePreview)
        case unavailable
        case running
        case finished(DockerManager.PruneResult)
    }

    @State private var phase: Phase = .loading

    private var docker: DockerManager { appState.dockerManager }

    private var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 300)
        .interactiveDismissDisabled(isRunning)
        .task { await loadPreview() }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: kind == .images ? "shippingbox" : "hammer")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text("Clean \(kind.title.lowercased())").font(.title3.weight(.semibold))
                Text(kind.warning)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking what can be removed…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        case .unavailable:
            NoticeBanner(tone: .error, message: "Couldn't read Docker disk usage. Make sure Docker is running and try again.")
        case .preview(let preview):
            previewList(preview)
        case .running:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Removing \(kind.title.lowercased())… this can take a minute.")
                }
                output
            }
        case .finished(let result):
            VStack(alignment: .leading, spacing: 8) {
                if result.success {
                    Label("Done — freed \(result.message)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                } else {
                    Label("Cleanup failed: \(result.message)", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                output
            }
        }
    }

    private func previewList(_ preview: DockerPrunePreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if preview.rows.isEmpty {
                Label("Nothing to clean: every \(kind.noun(count: 1)) is in use.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            } else {
                HStack {
                    Text("\(preview.rows.count) \(kind.noun(count: preview.rows.count)) will be removed")
                        .font(.headline)
                    Spacer()
                    // Docker's own figure: cache entries share data, so summing rows overcounts.
                    Text("about \(docker.diskUsage?.item(for: kind)?.reclaimable ?? preview.totalSize)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.orange)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(preview.rows) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.title)
                                        .font(.system(size: 12, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if !row.detail.isEmpty {
                                        Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                                Text(row.size)
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5)
                            .padding(.horizontal, 8)
                            Divider()
                        }
                    }
                }
                .frame(height: 240)
                .laradeckCard()
            }
            HStack(spacing: 6) {
                Text(kind.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(kind.command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy command")
            }
        }
    }

    private var output: some View {
        TerminalOutputView(source: docker.pruneOutput, isActive: isRunning)
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
    }

    @ViewBuilder private var footer: some View {
        HStack {
            Spacer()
            switch phase {
            case .loading, .unavailable:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            case .preview(let preview):
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Remove \(preview.rows.count) \(kind.noun(count: preview.rows.count))", role: .destructive) {
                    Task { await runPrune() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preview.rows.isEmpty || docker.pruning != nil)
            case .running:
                Button("Close") {}
                    .disabled(true)
            case .finished:
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Actions

    private func loadPreview() async {
        if let preview = await docker.prunePreview(kind) {
            phase = .preview(preview)
        } else {
            phase = .unavailable
        }
    }

    private func runPrune() async {
        phase = .running
        let result = await docker.prune(kind)
        phase = .finished(result)
    }
}
