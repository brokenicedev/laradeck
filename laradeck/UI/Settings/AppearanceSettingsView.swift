import SwiftUI

/// Settings → Appearance: pick the app-wide theme, or follow the OS (Midnight / Daylight).
struct AppearanceSettingsView: View {
    var body: some View {
        @Bindable var store = ThemeStore.shared

        Form {
            Section {
                Toggle("Sync with OS", isOn: $store.syncWithSystem)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                    ForEach(AppTheme.all) { theme in
                        ThemeCard(theme: theme, selected: store.theme.name == theme.name)
                            .onTapGesture { store.select(theme) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(theme.name)
                    }
                }
                .opacity(store.syncWithSystem ? 0.5 : 1)
                Toggle("Animated background", isOn: $store.animatedBackground)
            } header: {
                Text("Theme")
            } footer: {
                Text("“Sync with OS” uses Daylight in light mode and Midnight in dark mode. Picking a theme turns it off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Small preview drawn from the theme's own colors.
private struct ThemeCard: View {
    let theme: AppTheme
    let selected: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [theme.windowStart, theme.windowEnd], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 3) {
                    theme.header.frame(height: 8)
                    ForEach(0..<3) { i in
                        HStack(spacing: 3) {
                            [Color.green, .orange, .purple][i].frame(width: 2)
                            RoundedRectangle(cornerRadius: 1)
                                .fill(i == 1 ? theme.dumpString : theme.text.opacity(0.7))
                                .frame(width: CGFloat(28 + i * 8), height: 3)
                        }
                        .frame(height: 8)
                        .padding(.horizontal, 4)
                    }
                }
            }
            .frame(height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? theme.accent : Color.secondary.opacity(0.3), lineWidth: selected ? 2 : 1)
            )
            Text(theme.name).font(.caption)
        }
        .contentShape(Rectangle())
    }
}
