import SwiftUI

/// Logo style, custom image and initials background color — shared by import wizard and edit sheet.
struct ProjectAppearanceSection: View {
    let previewProject: Project
    var overrideIconPath: String?
    @Binding var iconStyle: ProjectIconStyle
    @Binding var color: Color
    var iconImportError: String?
    let onChooseImage: () -> Void
    let onRemoveImage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Logo", systemImage: "photo")
                .font(.headline)

            HStack(alignment: .top, spacing: 20) {
                ProjectFaviconView(
                    project: previewProject,
                    overrideIconPath: iconStyle == .customImage ? overrideIconPath : nil,
                    size: 72
                )

                VStack(alignment: .leading, spacing: 12) {
                    Picker("Logo style", selection: $iconStyle) {
                        Text("Custom image").tag(ProjectIconStyle.customImage)
                        Text("Initials").tag(ProjectIconStyle.initials)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: iconStyle) { _, newStyle in
                        if newStyle == .initials {
                            onRemoveImage()
                        }
                    }

                    if iconStyle == .customImage {
                        HStack(spacing: 10) {
                            Button("Choose Image…", action: onChooseImage)
                            if overrideIconPath != nil {
                                Button("Remove", action: onRemoveImage)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("PNG, JPEG, GIF, WebP, SVG, or ICO from your Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let iconImportError {
                            Text(iconImportError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    ProjectColorSwatchPicker(color: $color)
                }
            }
            .padding(16)
            .laradeckCard(cornerRadius: 10)
        }
    }
}
