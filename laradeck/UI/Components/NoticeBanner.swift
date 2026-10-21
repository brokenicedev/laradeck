import SwiftUI
import AppKit

/// Soft status banner matching dashboard Sail alerts (Bootstrap-like warning / error / info).
struct NoticeBanner: View {
    enum Tone {
        case warning
        case error
        case info
        case success

        var icon: String {
            switch self {
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "exclamationmark.triangle.fill"
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            }
        }

        var foreground: Color {
            switch self {
            case .warning: return Color(red: 0.72, green: 0.45, blue: 0.05)
            case .error: return Color(red: 0.85, green: 0.2, blue: 0.2)
            case .info: return Color(red: 0.15, green: 0.4, blue: 0.75)
            case .success: return Color(red: 0.1, green: 0.55, blue: 0.25)
            }
        }

        var background: Color {
            switch self {
            case .warning: return Color.orange.opacity(0.16)
            case .error: return Color.red.opacity(0.10)
            case .info: return Color.blue.opacity(0.12)
            case .success: return Color.green.opacity(0.12)
            }
        }

        var border: Color {
            switch self {
            case .warning: return Color.orange.opacity(0.40)
            case .error: return Color.red.opacity(0.28)
            case .info: return Color.blue.opacity(0.30)
            case .success: return Color.green.opacity(0.30)
            }
        }
    }

    let tone: Tone
    let message: String
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tone.icon)
                .foregroundStyle(tone.foreground)
                .padding(.top, 1)
            Text(message)
                .font(.callout)
                .foregroundStyle(tone.foreground)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tone.border, lineWidth: 1)
        }
    }
}

/// Secondary path with dotted underline — opens the folder in Finder.
struct PathLinkButton: View {
    let path: String
    var lineLimit: Int = 2

    var body: some View {
        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
        } label: {
            Text(path)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .underline(pattern: .dot)
                .lineLimit(lineLimit)
                .truncationMode(.middle)
                .multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
        .help("Open Folder")
    }
}

/// External URL styled like a classic system hyperlink.
struct LinkLabel: View {
    let url: URL
    var title: String? = nil

    var body: some View {
        Link(destination: url) {
            Label(title ?? url.absoluteString, systemImage: "link")
        }
        .foregroundStyle(Color(nsColor: .linkColor))
        .font(.callout)
    }
}
