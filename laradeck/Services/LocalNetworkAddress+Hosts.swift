import Foundation
import SystemConfiguration

/// How colleagues on the same network reach this Mac (shared databases).
extension LocalNetworkAddress {
    /// IPv4 addresses of active Wi-Fi / Ethernet interfaces, private ranges first.
    nonisolated static func ipv4Addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = pointer.pointee
            let flags = Int32(ifa.ifa_flags)
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  String(cString: ifa.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if !ip.hasPrefix("169.254."), !found.contains(ip) { found.append(ip) }
        }
        return found.sorted { isPrivate($0) && !isPrivate($1) }
    }

    /// Bonjour name, e.g. "Lucas-MacBook-Pro.local". Survives DHCP address changes.
    nonisolated static func bonjourHostName() -> String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) as String? else { return nil }
        return "\(name).local"
    }

    private nonisolated static func isPrivate(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1]))
    }
}
