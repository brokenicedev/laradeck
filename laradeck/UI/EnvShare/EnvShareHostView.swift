import SwiftUI

/// Host UI: show PIN while advertising `.env` on the local network.
struct EnvShareHostView: View {
    @Environment(\.dismiss) private var dismiss

    let project: Project
    @State private var service = EnvShareService()
    @State private var startError: String?

    var body: some View {
        @Bindable var service = service

        VStack(alignment: .leading, spacing: 16) {
            Text("Share .env on LAN")
                .font(.title2.bold())

            Text("Your colleague opens Receive .env in Laradeck, picks this Mac, and enters the PIN. Transfer is encrypted. Only share on trusted networks.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let startError {
                Text(startError)
                    .foregroundStyle(.red)
            } else if service.didShareSuccessfully {
                deliveredBadge(status: service.statusMessage)
            } else if service.isHosting {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PIN")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(service.pin)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .textSelection(.enabled)
                        .tracking(4)
                    Text(service.statusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .laradeckCard(cornerRadius: 10)
            } else if let lastError = service.lastError {
                endedBadge(message: lastError, isError: true)
            } else {
                ProgressView("Starting…")
            }

            Spacer(minLength: 0)

            HStack {
                Button(service.didShareSuccessfully ? "Done" : "Stop & Close") {
                    service.stopHosting()
                    dismiss()
                }
                .keyboardShortcut(service.didShareSuccessfully ? .defaultAction : .cancelAction)
                Spacer()
            }
        }
        .padding(24)
        .frame(width: 420, height: 340)
        .onAppear {
            do {
                try service.startHosting(project: project)
            } catch {
                startError = error.localizedDescription
            }
        }
        .onDisappear {
            service.stopHosting()
        }
    }

    private func deliveredBadge(status: String) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 72, height: 72)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
                    .symbolRenderingMode(.hierarchical)
            }

            Text("Received")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)

            Text(status.isEmpty ? "Your colleague received the .env." : status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("Sharing has stopped — you can close this window.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.green.opacity(0.08))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.green.opacity(0.35), lineWidth: 1.5)
        }
        .accessibilityLabel("Colleague received the shared environment file")
    }

    private func endedBadge(message: String, isError: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(isError ? "Share ended" : "Stopped", systemImage: isError ? "exclamationmark.triangle.fill" : "stop.circle")
                .font(.headline)
                .foregroundStyle(isError ? .orange : .secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .laradeckCard(cornerRadius: 10)
    }
}
