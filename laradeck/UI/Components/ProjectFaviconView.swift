import SwiftUI
import AppKit

/// Shows a project's custom logo or a colored initials avatar.
struct ProjectFaviconView: View {
    let project: Project
    var overrideIconPath: String? = nil
    var size: CGFloat = 20

    @State private var image: NSImage?

    private var iconPath: String? {
        overrideIconPath ?? project.customIconPath
    }

    private var usesCustomImage: Bool {
        project.effectiveIconStyle == .customImage || (overrideIconPath != nil && iconPath != nil)
    }

    private var showsCustomImage: Bool {
        usesCustomImage && iconPath != nil
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(backgroundColor)
            content
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .task(id: taskKey) {
            if showsCustomImage, let path = iconPath {
                image = await Self.loadIcon(at: path, pixelSize: size)
            } else {
                image = nil
            }
        }
    }

    private var taskKey: String {
        "\(project.path)|\(project.effectiveIconStyle.rawValue)|\(iconPath ?? "")|\(project.effectiveColorHex)|\(size)"
    }

    @ViewBuilder
    private var content: some View {
        if showsCustomImage, let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .padding(size * 0.1)
        } else {
            Text(Self.initials(for: project.name))
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
    }

    private var backgroundColor: Color {
        Color(hex: project.effectiveColorHex)
    }

    static func initials(for name: String) -> String {
        let words = name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .filter { !$0.isEmpty }

        if words.count >= 2 {
            return (words[0].prefix(1) + words[1].prefix(1)).uppercased()
        } else if let word = words.first {
            return String(word.prefix(2)).uppercased()
        }
        return "?"
    }

    private nonisolated static func loadIcon(at path: String, pixelSize: CGFloat) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        let side = max(pixelSize * 2, 64)

        if path.lowercased().hasSuffix(".svg") {
            return loadSVG(at: url, side: side)
        }

        guard let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: side, height: side)
        return image
    }

    private nonisolated static func loadSVG(at url: URL, side: CGFloat) -> NSImage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: side, height: side)
        return image
    }
}
