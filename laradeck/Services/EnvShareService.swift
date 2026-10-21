import Foundation
import Network
import CryptoKit
import Observation

/// Bonjour service type advertised while sharing a `.env` on the local network.
enum EnvShareBonjour {
    static let serviceType = "_laradeck-env._tcp"
}

struct EnvSharePeer: Identifiable, Hashable {
    let id: String
    /// Shared project name from the host.
    let name: String
    /// Host Mac / computer name when advertised.
    let hostName: String?
    /// Best-effort LAN IPv4 from the host TXT record.
    let ipAddress: String?
    /// Initials avatar color (hex) from the host project, when present.
    let colorHex: String?
    let endpoint: NWEndpoint
    let salt: Data

    var subtitle: String {
        let parts = [hostName, ipAddress].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        return parts.isEmpty ? "Laradeck share on your network" : parts.joined(separator: " · ")
    }
}

enum EnvShareError: LocalizedError {
    case missingEnv
    case badPin
    case cancelled
    case protocolFailure(String)
    case decryptFailed
    case timedOut

    var errorDescription: String? {
        switch self {
        case .missingEnv: return "This project has no .env file to share."
        case .badPin: return "Incorrect PIN."
        case .cancelled: return "Share cancelled."
        case .protocolFailure(let message): return message
        case .decryptFailed: return "Could not decrypt the shared .env (wrong PIN or corrupt data)."
        case .timedOut: return "Share session timed out."
        }
    }
}

/// Hosts or receives a short-lived `.env` transfer over Bonjour + PIN.
@MainActor
@Observable
final class EnvShareService {
    private(set) var isHosting = false
    /// True after the encrypted `.env` was sent to a peer (host side).
    private(set) var didShareSuccessfully = false
    private(set) var pin: String = ""
    private(set) var hostProjectName: String = ""
    private(set) var statusMessage: String = ""
    private(set) var discoveredPeers: [EnvSharePeer] = []
    private(set) var lastError: String?

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var hostSalt = Data()
    private var hostEnvContents = ""
    private var hostTimeoutTask: Task<Void, Never>?
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]

    // MARK: - Host

    func startHosting(project: Project, sessionMinutes: Int = 5) throws {
        stopHosting()
        lastError = nil
        didShareSuccessfully = false

        guard let contents = EnvFileIO.read(at: project.path), !contents.isEmpty else {
            throw EnvShareError.missingEnv
        }

        hostEnvContents = contents
        hostProjectName = project.name
        pin = String(format: "%06d", Int.random(in: 0...999_999))
        hostSalt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        let listener = try NWListener(using: parameters)
        let computerName = Host.current().localizedName
            ?? ProcessInfo.processInfo.hostName
        listener.service = NWListener.Service(
            name: "Laradeck \(project.name)",
            type: EnvShareBonjour.serviceType,
            txtRecord: NWTXTRecord([
                "name": project.name,
                "salt": hostSalt.base64EncodedString(),
                "host": computerName,
                "ip": LocalNetworkAddress.primaryIPv4() ?? "",
                "color": project.effectiveColorHex,
            ])
        )

        listener.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                guard let self else { return }
                switch newState {
                case .ready:
                    self.statusMessage = "Waiting for a colleague on the local network…"
                case .failed(let error):
                    self.lastError = error.localizedDescription
                    self.stopHosting()
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.acceptHostConnection(connection)
            }
        }

        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
        isHosting = true
        statusMessage = "Share started — give the PIN to your colleague."

        hostTimeoutTask?.cancel()
        hostTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(sessionMinutes * 60))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.isHosting, !self.didShareSuccessfully else { return }
                self.lastError = EnvShareError.timedOut.localizedDescription
                self.stopHosting()
            }
        }
    }

    func stopHosting() {
        hostTimeoutTask?.cancel()
        hostTimeoutTask = nil
        listener?.cancel()
        listener = nil
        for connection in activeConnections.values {
            connection.cancel()
        }
        activeConnections.removeAll()
        isHosting = false
        // Preserve success badge until the host sheet is dismissed / restarted.
        if !didShareSuccessfully {
            pin = ""
            statusMessage = ""
        }
        hostEnvContents = ""
    }

    /// Stops Bonjour advertising after a successful handoff so the PIN cannot be reused.
    /// Keeps `didShareSuccessfully` so the host UI can show a clear received badge.
    private func finishHostingAfterSuccessfulShare() {
        guard !didShareSuccessfully else { return }
        hostTimeoutTask?.cancel()
        hostTimeoutTask = nil
        listener?.cancel()
        listener = nil
        for connection in activeConnections.values {
            connection.cancel()
        }
        activeConnections.removeAll()
        hostEnvContents = ""
        pin = ""
        isHosting = false
        didShareSuccessfully = true
        statusMessage = "Your colleague received the .env."
        lastError = nil
    }

    private func acceptHostConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        activeConnections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .failed, .cancelled:
                    self.activeConnections.removeValue(forKey: id)
                default:
                    break
                }
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receiveAuthLine(on: connection)
    }

    private func receiveAuthLine(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    // Peer closed after a probe / finished transfer — not a user-facing failure.
                    if Self.isBenignStreamEnd(error) || isComplete {
                        connection.cancel()
                        return
                    }
                    self.statusMessage = error.localizedDescription
                    connection.cancel()
                    return
                }
                guard let data, !data.isEmpty, let line = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
                    connection.cancel()
                    return
                }

                let expected = "PIN \(self.pin)"
                guard line == expected || line.hasPrefix("PIN \(self.pin)") else {
                    self.sendHostText("ERR bad-pin\n", on: connection) {
                        connection.cancel()
                    }
                    self.statusMessage = "Someone tried to connect with a wrong PIN."
                    return
                }

                do {
                    let sealed = try Self.encrypt(self.hostEnvContents, pin: self.pin, salt: self.hostSalt)
                    var payload = Data("OK \(sealed.count)\n".utf8)
                    payload.append(sealed)
                    self.statusMessage = "Sending encrypted .env…"
                    connection.send(content: payload, completion: .contentProcessed { [weak self] sendError in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            connection.cancel()
                            // Receiver often closes as soon as the ciphertext is read; Network.framework
                            // then reports a stream error even though the handoff succeeded.
                            if let sendError, !Self.isBenignStreamEnd(sendError) {
                                self.statusMessage = "Delivered (peer closed the connection)."
                            }
                            self.finishHostingAfterSuccessfulShare()
                        }
                    })
                } catch {
                    self.sendHostText("ERR encrypt\n", on: connection) {
                        connection.cancel()
                    }
                }
            }
        }
    }

    private func sendHostText(_ text: String, on connection: NWConnection, completion: @escaping () -> Void) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in
            completion()
        })
    }

    // MARK: - Browse / receive

    func startBrowsing() {
        stopBrowsing()
        lastError = nil
        discoveredPeers = []
        statusMessage = "Searching the local network…"

        // `.bonjour` never fills TXT metadata — we need salt from the host's TXT record,
        // so browse with `.bonjourWithTXTRecord` or every peer is silently dropped.
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: EnvShareBonjour.serviceType,
            domain: nil
        )
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        let browser = NWBrowser(for: descriptor, using: parameters)
        browser.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch newState {
                case .ready:
                    if self.discoveredPeers.isEmpty {
                        self.statusMessage = "Searching the local network…"
                    }
                case .failed(let error):
                    self.lastError = error.localizedDescription
                    self.statusMessage = ""
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let peers = results.compactMap { Self.peer(from: $0) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self.discoveredPeers = peers
                if peers.isEmpty {
                    self.statusMessage = results.isEmpty
                        ? "Searching the local network…"
                        : "Found a share but it is missing transfer metadata — ask them to stop and share again."
                } else {
                    self.statusMessage = "Found \(peers.count) share\(peers.count == 1 ? "" : "s")."
                }
            }
        }
        browser.start(queue: .global(qos: .userInitiated))
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        discoveredPeers = []
    }

    func receive(from peer: EnvSharePeer, pin: String) async throws -> String {
        lastError = nil
        let trimmed = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 6, trimmed.allSatisfy(\.isNumber) else {
            throw EnvShareError.badPin
        }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: peer.endpoint, using: parameters)
        connection.start(queue: .global(qos: .userInitiated))

        try await waitUntilReady(connection)
        try await send(Data("PIN \(trimmed)\n".utf8), on: connection)

        // Header + ciphertext often arrive in one TCP segment — keep leftover bytes for the payload.
        var inbox = Data()
        let headerData = try await receiveLine(into: &inbox, on: connection, maxBytes: 128)
        guard let header = String(data: headerData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            connection.cancel()
            throw EnvShareError.protocolFailure("Empty response from peer.")
        }

        if header.hasPrefix("ERR") {
            connection.cancel()
            throw EnvShareError.badPin
        }

        guard header.hasPrefix("OK "),
              let count = Int(header.dropFirst(3).trimmingCharacters(in: .whitespaces)) else {
            connection.cancel()
            throw EnvShareError.protocolFailure("Unexpected response: \(header)")
        }

        let sealed = try await receiveExact(count, into: &inbox, on: connection)
        connection.cancel()

        do {
            return try Self.decrypt(sealed, pin: trimmed, salt: peer.salt)
        } catch {
            throw EnvShareError.decryptFailed
        }
    }

    // MARK: - Crypto

    nonisolated static func deriveKey(pin: String, salt: Data) -> SymmetricKey {
        var material = Data("laradeck-env-v1".utf8)
        material.append(0)
        material.append(Data(pin.utf8))
        material.append(salt)
        return SymmetricKey(data: SHA256.hash(data: material))
    }

    nonisolated static func encrypt(_ plaintext: String, pin: String, salt: Data) throws -> Data {
        let key = deriveKey(pin: pin, salt: salt)
        let sealed = try ChaChaPoly.seal(Data(plaintext.utf8), using: key)
        return sealed.combined
    }

    nonisolated static func decrypt(_ sealedCombined: Data, pin: String, salt: Data) throws -> String {
        let key = deriveKey(pin: pin, salt: salt)
        let box = try ChaChaPoly.SealedBox(combined: sealedCombined)
        let plain = try ChaChaPoly.open(box, using: key)
        guard let string = String(data: plain, encoding: .utf8) else {
            throw EnvShareError.decryptFailed
        }
        return string
    }

    // MARK: - Helpers

    private static func peer(from result: NWBrowser.Result) -> EnvSharePeer? {
        var name = "Laradeck"
        var hostName: String?
        var ipAddress: String?
        var colorHex: String?
        var salt = Data()
        if case .bonjour(let record) = result.metadata {
            if let value = record["name"], !value.isEmpty {
                name = value
            }
            if let value = record["host"], !value.isEmpty {
                hostName = value
            }
            if let value = record["ip"], !value.isEmpty {
                ipAddress = value
            }
            if let value = record["color"], !value.isEmpty {
                colorHex = value
            }
            if let saltB64 = record["salt"], let decoded = Data(base64Encoded: saltB64) {
                salt = decoded
            }
        }
        if name == "Laradeck", case .service(let serviceName, _, _, _) = result.endpoint {
            let trimmed = serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("Laradeck ") {
                name = String(trimmed.dropFirst("Laradeck ".count))
            } else if !trimmed.isEmpty {
                name = trimmed
            }
        }
        guard !salt.isEmpty else { return nil }
        let id = String(describing: result.endpoint)
        return EnvSharePeer(
            id: id,
            name: name,
            hostName: hostName,
            ipAddress: ipAddress,
            colorHex: colorHex,
            endpoint: result.endpoint,
            salt: salt
        )
    }

    private func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let lock = NSLock()
            var resumed = false
            let resumeOnce: @Sendable (Result<Void, Error>) -> Void = { result in
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(.success(()))
                case .failed(let error):
                    resumeOnce(.failure(error))
                case .cancelled:
                    resumeOnce(.failure(EnvShareError.cancelled))
                default:
                    break
                }
            }
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Reads until `\n`, leaving any trailing bytes in `inbox` for the next framed read.
    private func receiveLine(into inbox: inout Data, on connection: NWConnection, maxBytes: Int) async throws -> Data {
        while true {
            if let index = inbox.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(inbox[...index])
                inbox.removeSubrange(...index)
                return line
            }
            guard inbox.count < maxBytes else {
                throw EnvShareError.protocolFailure("Response header too long.")
            }
            let chunk = try await receiveChunk(on: connection, maximumLength: maxBytes)
            if chunk.isEmpty {
                throw EnvShareError.protocolFailure("Connection closed before response header.")
            }
            inbox.append(chunk)
        }
    }

    private func receiveExact(_ count: Int, into inbox: inout Data, on connection: NWConnection) async throws -> Data {
        while inbox.count < count {
            let needed = count - inbox.count
            let chunk = try await receiveChunk(on: connection, maximumLength: max(needed, 1))
            if chunk.isEmpty {
                throw EnvShareError.protocolFailure("Connection closed before payload finished.")
            }
            inbox.append(chunk)
        }
        let sealed = Data(inbox.prefix(count))
        inbox.removeFirst(count)
        return sealed
    }

    private func receiveChunk(on connection: NWConnection, maximumLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                if let error {
                    if isComplete || Self.isBenignStreamEnd(error) {
                        continuation.resume(returning: data ?? Data())
                    } else {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }

    /// POSIX / Network.framework EOF after the peer closes — not a real transfer failure.
    nonisolated private static func isBenignStreamEnd(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            // ECONNRESET, ENOTCONN, EPIPE, ECONNABORTED
            if [54, 57, 32, 53].contains(nsError.code) { return true }
        }
        if nsError.domain == "Network.NWError", nsError.code == 96 {
            return true
        }
        let text = error.localizedDescription.lowercased()
        return text.contains("no message available on stream")
            || text.contains("socket is not connected")
            || text.contains("connection reset")
            || text.contains("broken pipe")
            || text.contains("not connected")
    }
}

/// Best-effort LAN IPv4 for Bonjour TXT (no TCP connect required on the browser side).
enum LocalNetworkAddress {
    nonisolated static func primaryIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        let preferredPrefixes = ["en", "bridge", "wlan"]
        var preferred: String?
        var fallback: String?

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let iface = pointer {
            defer { pointer = iface.pointee.ifa_next }
            guard let addr = iface.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: iface.pointee.ifa_name)
            if name == "lo0" || name.hasPrefix("lo") { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let ip = String(cString: hostname)
            if ip.hasPrefix("127.") { continue }

            if preferredPrefixes.contains(where: { name.hasPrefix($0) }) {
                preferred = preferred ?? ip
            } else {
                fallback = fallback ?? ip
            }
        }
        return preferred ?? fallback
    }
}
