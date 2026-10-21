import SwiftUI

/// Marks a process that accepts keyboard input in Logs.
struct InteractiveCommandBadge: View {
    var body: some View {
        Label("Interactive", systemImage: "keyboard")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Self.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Self.tint.opacity(0.12), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Self.tint.opacity(0.28), lineWidth: 1)
            }
            .accessibilityLabel("Interactive command")
    }

    static let tint = Color(red: 0.15, green: 0.4, blue: 0.75)
}
