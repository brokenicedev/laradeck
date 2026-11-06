import AppKit
import SwiftUI

/// Docker section of the toolbar popover: how much space images and build cache take, how much a
/// prune would free, the matching Terminal command, and a button that opens the cleanup sheet.
struct DockerDiskUsageView: View {
    @Environment(AppState.self) private var appState
    /// Opens the cleanup sheet (the popover closes first, so the sheet isn't hidden behind it).
    let onClean: (DockerPruneKind) -> Void

    private var docker: DockerManager { appState.dockerManager }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Disk usage").font(.subheadline.weight(.semibold))
                if docker.isLoadingDiskUsage {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                Button {
                    Task { await docker.refreshDiskUsage() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(docker.isLoadingDiskUsage || docker.pruning != nil)
                .help("Refresh")
            }

            if let usage = docker.diskUsage {
                ForEach(DockerPruneKind.allCases) { kind in
                    row(kind, item: usage.item(for: kind))
                }
            } else if !docker.isLoadingDiskUsage {
                Text("Couldn't read Docker disk usage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message = docker.lastPruneMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 6)
        .task { await docker.refreshDiskUsage() }
    }

    private func row(_ kind: DockerPruneKind, item: DockerDiskUsage.Item?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(kind.title).font(.callout)
                Spacer(minLength: 4)
                Text(item?.size ?? "—")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(item == nil ? .secondary : .primary)
                if docker.pruning == kind {
                    ProgressView().controlSize(.mini)
                } else {
                    Button("Clean…") { onClean(kind) }
                        .controlSize(.small)
                        .disabled(!(item?.hasReclaimable ?? false) || docker.pruning != nil)
                        .help("Preview and run \(kind.command)")
                }
            }
            if let item {
                Text("\(item.reclaimable) reclaimable · \(item.count) \(kind == .images ? "images" : "entries")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(item.hasReclaimable ? Color.orange : Color.secondary)
            }
            HStack(spacing: 4) {
                Text(kind.command)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(kind.command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 9))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help("Copy command")
            }
        }
    }
}
