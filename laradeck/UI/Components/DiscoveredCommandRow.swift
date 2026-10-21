import SwiftUI

/// A selectable row for a discovered npm/composer/artisan command — matches the project wizard look.
struct DiscoveredCommandRow: View {
    let name: String
    let sourceBadge: String
    let commandPreview: String
    var description: String? = nil
    var monospacedName: Bool = false
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.55))
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(monospacedName ? .body.weight(.medium).monospaced() : .body.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(sourceBadge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary.opacity(0.6), in: Capsule())
                    }
                    if let description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Text(commandPreview)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                isSelected ? Color.accentColor.opacity(0.1) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
