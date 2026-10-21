import SwiftUI

/// Shows the current git branch for a project dashboard header.
struct GitBranchBadge: View {
    let branch: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch")
            Text(branch)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.45), in: Capsule())
        .help("Current git branch")
        .accessibilityLabel("Git branch \(branch)")
    }
}
