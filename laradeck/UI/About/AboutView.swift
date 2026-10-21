import SwiftUI

/// About Laradeck — app info, credits and community links in one panel.
struct AboutView: View {
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    AboutSection(
                        icon: "star.fill",
                        iconColor: .yellow,
                        title: "Enjoying Laradeck?",
                        message: "If the app saves you time juggling terminals, queues and Docker — leave a star on GitHub. It helps others discover the project.",
                        actions: [
                            AboutAction("Star on GitHub", url: AppLinks.githubRepository, prominent: true),
                        ]
                    )

                    AboutSection(
                        icon: "questionmark.circle.fill",
                        iconColor: .accentColor,
                        title: "Having issues?",
                        message: "Check the README for setup notes (Sail, Docker, package managers) or open an issue if something looks wrong.",
                        actions: [
                            AboutAction("Read the docs", url: AppLinks.githubReadme),
                            AboutAction("Report an issue", url: AppLinks.githubIssues),
                        ]
                    )

                    AboutSection(
                        icon: "hand.raised.fill",
                        iconColor: .green,
                        title: "Privacy",
                        message: "Laradeck stores your projects and settings locally on your Mac. It does not send telemetry or project data to our servers. On launch it may request a public version feed (version.json) to tell you when an update is available. Optional Share .env on LAN sends encrypted .env contents only to another Laradeck on your local network after you share a PIN — nothing is uploaded to the internet.",
                        actions: [
                            AboutAction("Contact us", url: AppLinks.contactEmail),
                        ]
                    )

                    AboutSection(
                        icon: "arrow.down.app.fill",
                        iconColor: .blue,
                        title: "Updates",
                        message: updatesMessage,
                        actions: updatesActions
                    )

                    AboutSection(
                        icon: "heart.fill",
                        iconColor: .pink,
                        title: "Support development",
                        message: "Laradeck is free and open source. If you want to support continued work on the app, get in touch — we'd love to hear from you.",
                        actions: [
                            AboutAction("brokenice.it", url: AppLinks.brokenice),
                            AboutAction("Email hello@brokenice.it", url: AppLinks.contactEmail),
                        ]
                    )

                    AboutSection(
                        icon: "bell.fill",
                        iconColor: .orange,
                        title: "Stay updated",
                        message: "Watch the GitHub repository for releases and follow brokenice.it for news about Laradeck and other tools we ship.",
                        actions: [
                            AboutAction("Releases on GitHub", url: AppLinks.githubReleases),
                            AboutAction("brokenice.it", url: AppLinks.brokenice),
                        ]
                    )

                    AboutSection(
                        icon: "sparkles",
                        iconColor: .purple,
                        title: "Special thanks",
                        message: "Thanks to everyone who tries Laradeck during the beta, reports bugs, and shares feedback — you make the next version better.",
                        actions: []
                    )
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .frame(width: 500, height: 560)
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 52, height: 52)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Laradeck")
                    .font(.title.bold())
                if let version = appVersion {
                    Text("Version \(version)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text("Free · Made by")
                        .foregroundStyle(.secondary)
                    Link("brokenice.it", destination: AppLinks.brokenice)
                }
                .font(.subheadline)
            }
            Spacer()
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("OK") { close() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var updatesMessage: String {
        switch AppDistributionChannel.current {
        case .appStore:
            return "When a newer build is published, Laradeck can open the Mac App Store listing. You can also check from Settings → Updates."
        case .direct:
            return "Laradeck checks a public version feed and can install direct updates automatically. Use Settings → Updates or Check for Updates in the Laradeck menu."
        }
    }

    private var updatesActions: [AboutAction] {
        [AboutAction("Releases on GitHub", url: AppLinks.githubReleases)]
    }

    private var appVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}

private struct AboutSection: View {
    let icon: String
    let iconColor: Color
    let title: String
    let message: String
    let actions: [AboutAction]

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !actions.isEmpty {
                    FlowLayout(spacing: 8) {
                        ForEach(actions) { action in
                            AboutActionButton(action: action)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }
}

private struct AboutAction: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
    var prominent: Bool = false

    init(_ title: String, url: URL, prominent: Bool = false) {
        self.title = title
        self.url = url
        self.prominent = prominent
    }
}

private struct AboutActionButton: View {
    let action: AboutAction

    var body: some View {
        Group {
            if action.prominent {
                Button(action.title) { AppLinks.open(action.url) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(action.title) { AppLinks.open(action.url) }
                    .buttonStyle(.laradeckOutline)
            }
        }
        .controlSize(.small)
    }
}

/// Simple horizontal wrap for action buttons.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var frames: [CGRect] = []

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), frames)
    }
}

#if os(macOS)
import AppKit
#endif
