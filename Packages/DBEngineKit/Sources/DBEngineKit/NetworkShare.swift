import Foundation
import Security

/// LAN access to a service through a dedicated password-protected user.
/// Local access (postgres / root without password) is left untouched.
public struct NetworkShare: Codable, Hashable, Sendable {
    public var user: String
    public var password: String

    public init(user: String, password: String) {
        self.user = user
        self.password = password
    }

    public static let defaultUser = "laradeck_share"

    /// Alphanumeric only, so it never needs quoting in SQL, URLs or .env files.
    public static func generate(user: String = defaultUser, length: Int = 24) -> NetworkShare {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        var bytes = [UInt8](repeating: 0, count: length)
        if SecRandomCopyBytes(kSecRandomDefault, length, &bytes) != errSecSuccess {
            bytes = (0..<length).map { _ in UInt8.random(in: .min ... .max) }
        }
        let password = String(bytes.map { alphabet[Int($0) % alphabet.count] })
        return NetworkShare(user: user, password: password)
    }

    // MARK: pg_hba.conf

    static let hbaBegin = "# BEGIN laradeck-share"
    static let hbaEnd = "# END laradeck-share"

    /// Adds (or replaces) the block that lets `user` log in from any address with a password.
    /// initdb's loopback `trust` lines come first, so local access stays password-free.
    public static func addingShareBlock(to hba: String, user: String) -> String {
        var text = removingShareBlock(from: hba)
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += """
        \(hbaBegin)
        host    all    \(user)    0.0.0.0/0    scram-sha-256
        host    all    \(user)    ::/0         scram-sha-256
        \(hbaEnd)

        """
        return text
    }

    /// Removes the block written by `addingShareBlock`, leaving the rest as it was.
    public static func removingShareBlock(from hba: String) -> String {
        var lines = hba.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: hbaBegin),
              let end = lines[start...].firstIndex(of: hbaEnd) else { return hba }
        lines.removeSubrange(start...end)
        return lines.joined(separator: "\n")
    }
}
