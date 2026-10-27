import SwiftUI

/// Small capsule used for the tags next to a project's name (environment, git branch):
/// same font, padding and fill, so every tag in the header is the same height.
struct HeaderBadge: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(HeaderBadgeLabelStyle())
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.secondary.opacity(0.15), in: Capsule())
    }
}

private struct HeaderBadgeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

/// Current git branch, as a header tag.
struct GitBranchBadge: View {
    let branch: String

    var body: some View {
        HeaderBadge(title: branch, systemImage: "arrow.triangle.branch")
            .help("Current git branch")
            .accessibilityLabel("Git branch \(branch)")
    }
}
