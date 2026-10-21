import DBEngineKit
import SwiftUI

/// "Share on network" switch for a local database, plus what colleagues need to connect.
struct NetworkShareCard: View {
    @Environment(AppState.self) private var appState
    let row: DatabaseManager.Row

    @State private var hosts: [String] = []
    @State private var showingPassword = false

    private var databases: DatabaseManager { appState.databaseManager }
    private var service: Service { row.service }
    private var isBusy: Bool { databases.busy.contains(row.id) }
    private var host: String { hosts.first ?? "127.0.0.1" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share on network")
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { service.isShared },
                    set: { databases.setNetworkShare(service, $0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!service.kind.supportsNetworkShare || isBusy)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            if let share = service.networkShare {
                Divider()
                row("Host", hosts.isEmpty ? "No network connection" : hosts.joined(separator: "  ·  "),
                    copy: hosts.isEmpty ? nil : host)
                Divider()
                row("Port", String(service.port), copy: String(service.port))
                Divider()
                row("User", share.user, copy: share.user)
                Divider()
                passwordRow(share.password)
                Divider()
                HStack {
                    Spacer()
                    Button("Copy .env") {
                        DatabaseManager.shareEnv(service, host: host).map(DatabaseManager.copy)
                    }
                    Button("Copy URL") {
                        DatabaseManager.shareConnectionURL(service, host: host)
                            .map { DatabaseManager.copy($0.absoluteString) }
                    }
                }
                .disabled(hosts.isEmpty)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
        }
        .laradeckCard()
        .task(id: service.isShared) { refreshHosts() }
    }

    private var caption: String {
        if !service.kind.supportsNetworkShare {
            return "Redis can't require a password from colleagues without also requiring it locally."
        }
        if service.isShared {
            return "Colleagues connect with the user below. Local access is unchanged. "
                + "macOS may ask to allow incoming connections."
        }
        return "Lets colleagues on the same network connect with a dedicated user and password. "
            + "The server restarts."
    }

    private func refreshHosts() {
        var list = LocalNetworkAddress.ipv4Addresses()
        if let name = LocalNetworkAddress.bonjourHostName() { list.append(name) }
        hosts = list
    }

    private func row(_ label: String, _ value: String, copy: String?) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            if let copy { copyButton(copy) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func passwordRow(_ password: String) -> some View {
        HStack {
            Text("Password")
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(showingPassword ? password : String(repeating: "•", count: 12))
                .font(.body.monospaced())
                .textSelection(.enabled)
            Spacer()
            Button {
                showingPassword.toggle()
            } label: {
                Image(systemName: showingPassword ? "eye.slash" : "eye")
            }
            .buttonStyle(.laradeckIcon())
            .help(showingPassword ? "Hide password" : "Show password")
            copyButton(password)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func copyButton(_ text: String) -> some View {
        Button {
            DatabaseManager.copy(text)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.laradeckIcon())
        .help("Copy")
    }
}
