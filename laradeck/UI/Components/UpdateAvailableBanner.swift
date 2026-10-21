import SwiftUI

/// Non-modal banner shown when `VersionCheckService` finds a newer release.
struct UpdateAvailableBanner: View {
    let info: AppVersionInfo
    let onUpdate: () -> Void
    let onLater: () -> Void
    let onSkip: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.down.app.fill")
                .font(.title3)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("Laradeck \(info.latest) is available")
                    .font(.callout.weight(.semibold))
                if let notes = info.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(updateSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Button("Later", action: onLater)
                .controlSize(.small)
            Button("Skip", action: onSkip)
                .controlSize(.small)
            Button(updateButtonTitle, action: onUpdate)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var updateButtonTitle: String {
        switch AppDistributionChannel.current {
        case .appStore: return "App Store"
        case .direct: return "Update"
        }
    }

    private var updateSubtitle: String {
        switch AppDistributionChannel.current {
        case .appStore: return "Get it from the Mac App Store."
        case .direct: return "A newer build is ready to install."
        }
    }
}
