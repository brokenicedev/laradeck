import Foundation

enum Port {
    /// True if something already accepts TCP connections on 127.0.0.1:port.
    /// (DBngin: "Port … is being used by another application.")
    static func isListening(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }

    /// Polls until the port accepts connections or the timeout passes.
    static func waitUntilListening(_ port: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isListening(port) { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return isListening(port)
    }
}
