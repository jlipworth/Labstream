import Foundation
import Darwin

/// Classifies the stream route from the resolved server address, not the host name.
///
/// A custom DNS name (a home domain, a reverse proxy, a name published for a VPN address) says
/// nothing about which side of the router it points at, so the host-only answer for it is
/// Unknown. This resolver looks the name up once and compares the address with this device's own
/// interfaces:
///
/// - on the subnet of a physical interface (Wi-Fi, Ethernet), or loopback → **Local**;
/// - on a tunnel interface's subnet, in the CGNAT range 100.64.0.0/10 that Tailscale and other
///   overlays use, or in Tailscale's IPv6 range → **VPN**;
/// - any other private address → **VPN** while a tunnel interface carries an address (e.g. a
///   Tailscale subnet router reaching the home LAN from outside), otherwise **Local** (another
///   subnet of the same network);
/// - a public address → **Remote**.
///
/// When the lookup fails the host-only classification stands. The host name and address never
/// leave this type: the panel and its Copy text show only the route title.
enum PlaybackConnectionRouteResolver {
    /// Raw network-order address bytes: 4 for IPv4, 16 for IPv6.
    struct Address: Equatable, Sendable {
        var bytes: [UInt8]

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        init?(literal: String) {
            var v4 = in_addr()
            if inet_pton(AF_INET, literal, &v4) == 1 {
                self.bytes = withUnsafeBytes(of: &v4) { Array($0) }
                return
            }
            var v6 = in6_addr()
            if inet_pton(AF_INET6, literal, &v6) == 1 {
                self.bytes = withUnsafeBytes(of: &v6) { Array($0) }
                return
            }
            return nil
        }

        var isV4: Bool { bytes.count == 4 }

        var isLoopback: Bool {
            isV4 ? bytes[0] == 127 : bytes == Array(repeating: 0, count: 15) + [1]
        }

        /// 100.64.0.0/10 (Tailscale and other overlays) or Tailscale's fd7a:115c:a1e0::/48.
        var isOverlay: Bool {
            isV4 ? bytes[0] == 100 && (64...127).contains(bytes[1])
                : bytes.starts(with: [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0])
        }

        /// RFC 1918, IPv4 link-local, IPv6 unique-local and link-local.
        var isPrivate: Bool {
            if isV4 {
                return bytes[0] == 10
                    || (bytes[0] == 172 && (16...31).contains(bytes[1]))
                    || (bytes[0] == 192 && bytes[1] == 168)
                    || (bytes[0] == 169 && bytes[1] == 254)
            }
            return (bytes[0] & 0xfe) == 0xfc || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80)
        }

        var isLinkLocal: Bool {
            isV4 ? bytes[0] == 169 && bytes[1] == 254
                : bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
        }
    }

    struct Interface: Equatable, Sendable {
        var name: String
        var address: Address
        var netmask: Address

        /// utun (Tailscale, WireGuard, other Network Extension VPNs), ipsec, ppp and similar.
        var isTunnel: Bool {
            ["utun", "ipsec", "ppp", "tun", "tap", "wg"].contains(where: name.hasPrefix)
        }

        func contains(_ other: Address) -> Bool {
            guard other.bytes.count == address.bytes.count,
                  netmask.bytes.count == address.bytes.count else { return false }
            return zip(zip(address.bytes, other.bytes), netmask.bytes)
                .allSatisfy { pair, mask in pair.0 & mask == pair.1 & mask }
        }
    }

    /// Resolves `rawHost` (`host`, `host:port`, or `[v6]:port`) off the main actor.
    static func resolve(host rawHost: String) async -> PlaybackConnectionRoute {
        let fallback = PlaybackConnectionRoute.classify(host: rawHost)
        guard fallback != .downloaded else { return fallback }
        let host = PlaybackConnectionRoute.bareHost(rawHost)
        guard !host.isEmpty, host != "—" else { return fallback }
        let route = await Task.detached(priority: .utility) { () -> PlaybackConnectionRoute? in
            guard let address = Address(literal: host) ?? lookUp(host) else { return nil }
            return classify(address, interfaces: currentInterfaces())
        }.value
        return route ?? fallback
    }

    /// Pure decision over an address and the device's interfaces (see the type comment).
    static func classify(_ address: Address, interfaces: [Interface]) -> PlaybackConnectionRoute {
        if address.isLoopback { return .local }
        if interfaces.contains(where: { !$0.isTunnel && $0.contains(address) }) { return .local }
        if address.isOverlay || interfaces.contains(where: { $0.isTunnel && $0.contains(address) }) {
            return .vpn
        }
        guard address.isPrivate else { return .remote }
        let tunnelActive = interfaces.contains { $0.isTunnel && !$0.address.isLinkLocal }
        return tunnelActive ? .vpn : .local
    }

    /// First address the system resolver returns, which is the one a connection tries first.
    private static func lookUp(_ host: String) -> Address? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }
        var entry: UnsafeMutablePointer<addrinfo>? = first
        while let info = entry?.pointee {
            if let address = info.ai_addr.flatMap(address(of:)) { return address }
            entry = info.ai_next
        }
        return nil
    }

    private static func currentInterfaces() -> [Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(first) }
        var interfaces: [Interface] = []
        var entry: UnsafeMutablePointer<ifaddrs>? = first
        while let item = entry?.pointee {
            defer { entry = item.ifa_next }
            guard (item.ifa_flags & UInt32(IFF_UP)) != 0,
                  let address = item.ifa_addr.flatMap(address(of:)),
                  let netmask = item.ifa_netmask.map({ mask(of: $0, like: address) }) else { continue }
            interfaces.append(Interface(name: String(cString: item.ifa_name),
                                        address: address, netmask: netmask))
        }
        return interfaces
    }

    /// Kernel netmask sockaddrs may be truncated (`sa_len` shorter than the struct) and leave
    /// `sa_family` unset, so read only `sa_len` bytes at the address family's offset and treat
    /// the rest as zero.
    private static func mask(of pointer: UnsafeMutablePointer<sockaddr>, like address: Address) -> Address {
        let offset = address.isV4 ? MemoryLayout<sockaddr_in>.offset(of: \.sin_addr)!
            : MemoryLayout<sockaddr_in6>.offset(of: \.sin6_addr)!
        let length = Int(pointer.pointee.sa_len)
        let raw = UnsafeRawPointer(pointer)
        let bytes = (0..<address.bytes.count).map { index -> UInt8 in
            offset + index < length ? raw.load(fromByteOffset: offset + index, as: UInt8.self) : 0
        }
        return Address(bytes)
    }

    private static func address(of sockaddrPointer: UnsafeMutablePointer<sockaddr>) -> Address? {
        switch Int32(sockaddrPointer.pointee.sa_family) {
        case AF_INET:
            return sockaddrPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                var raw = $0.pointee.sin_addr
                return Address(withUnsafeBytes(of: &raw) { Array($0) })
            }
        case AF_INET6:
            return sockaddrPointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                var raw = $0.pointee.sin6_addr
                return Address(withUnsafeBytes(of: &raw) { Array($0) })
            }
        default:
            return nil
        }
    }
}
