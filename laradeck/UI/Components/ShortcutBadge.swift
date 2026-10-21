import SwiftUI

/// Marks a process that's a one-off quick action — never tracked as a running process,
/// never included in Start All / Stop All.
struct ShortcutBadge: View {
    var body: some View {
        Label("Shortcut", systemImage: "bolt.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Self.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Self.tint.opacity(0.12), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Self.tint.opacity(0.28), lineWidth: 1)
            }
            .accessibilityLabel("Shortcut command — not included in Start All")
    }

    static let tint = Color.purple
}
