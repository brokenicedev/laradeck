import SwiftUI

/// Browse LAN peers, enter PIN, then hand off the received `.env` to the main window for apply/merge.
struct EnvReceiveView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var service = EnvShareService()
    @State private var selectedPeerId: String?
    @State private var pin = ""
    @State private var selectedProjectId: UUID?
    @State private var isReceiving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Receive .env")
                .font(.title2.bold())

            Text("Pick a nearby Laradeck share, then enter the PIN shown on their Mac and choose which project gets the file.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if service.discoveredPeers.isEmpty {
                    ContentUnavailableView(
                        "Looking for shares…",
                        systemImage: "wifi",
                        description: Text(service.statusMessage.isEmpty
                            ? "Ask your colleague to keep Share .env open, and allow Local Network for Laradeck in System Settings → Privacy & Security."
                            : service.statusMessage)
                    )
                    .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
                    .multilineTextAlignment(.center)
                } else {
                    List(service.discoveredPeers, selection: $selectedPeerId) { peer in
                        EnvSharePeerRow(peer: peer)
                            .tag(peer.id)
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    }
                    .frame(minHeight: 180)
                }
            }
            .frame(maxWidth: .infinity)

            if let browseError = service.lastError {
                Text(browseError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if selectedPeerId != nil {
                HStack {
                    Text("PIN")
                    TextField("000000", text: $pin)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .onChange(of: pin) { _, newValue in
                            pin = String(newValue.filter(\.isNumber).prefix(6))
                        }
                }

                Picker("Project", selection: $selectedProjectId) {
                    Text("Select…").tag(Optional<UUID>.none)
                    ForEach(appState.projects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Cancel") {
                    service.stopBrowsing()
                    dismiss()
                }
                Spacer()
                Button("Receive") {
                    Task { await receive() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selectedPeerId == nil || pin.count != 6 || selectedProjectId == nil || isReceiving)
            }
        }
        .padding(24)
        .frame(width: 520, height: 460)
        .onAppear {
            if selectedProjectId == nil {
                selectedProjectId = appState.selectedProjectId
            }
            service.startBrowsing()
        }
        .onChange(of: selectedPeerId) { _, _ in
            pin = ""
            errorMessage = nil
        }
        .onDisappear {
            service.stopBrowsing()
        }
    }

    private func receive() async {
        errorMessage = nil
        guard let peerId = selectedPeerId,
              let peer = service.discoveredPeers.first(where: { $0.id == peerId }),
              let projectId = selectedProjectId,
              let project = appState.project(withId: projectId) else { return }

        isReceiving = true
        defer { isReceiving = false }

        do {
            let contents = try await service.receive(from: peer, pin: pin)
            service.stopBrowsing()
            appState.selectedProjectId = project.id
            appState.pendingEnvReceive = IncomingEnvPayload(
                projectId: project.id,
                projectPath: project.path,
                projectName: project.name,
                incomingContents: contents
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct IncomingEnvPayload: Identifiable, Equatable {
    enum Phase: Equatable {
        /// Modal: Save / Overwrite / Merge.
        case chooseAction
        /// Full-window key-by-key merge editor.
        case mergeEditor
    }

    let id: UUID
    let projectId: UUID
    let projectPath: String
    let projectName: String
    let incomingContents: String
    var phase: Phase

    init(
        projectId: UUID,
        projectPath: String,
        projectName: String,
        incomingContents: String,
        phase: Phase = .chooseAction
    ) {
        self.id = UUID()
        self.projectId = projectId
        self.projectPath = projectPath
        self.projectName = projectName
        self.incomingContents = incomingContents
        self.phase = phase
    }
}

/// Peer row with initials avatar, project name, Mac name and LAN IP.
private struct EnvSharePeerRow: View {
    let peer: EnvSharePeer

    var body: some View {
        HStack(spacing: 12) {
            EnvSharePeerAvatar(name: peer.name, colorHex: peer.colorHex, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(peer.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(peer.subtitle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

private struct EnvSharePeerAvatar: View {
    let name: String
    let colorHex: String?
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(Color(hex: colorHex ?? ProjectColorPalette.defaultHex(for: name)))
            Text(ProjectFaviconView.initials(for: name))
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    }
}
