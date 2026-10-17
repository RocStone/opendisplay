import Darwin
import Network

/// Which paths the sender may use to reach a receiver. Automatic is the
/// long-standing policy: dial the receiver's Bonjour service over whatever
/// path Network.framework picks, then move the session onto a cable once
/// one turns up. Its weak spot is the first dial: resolution races every
/// address the record carries and the WiFi one often wins, and the upgrade
/// probe depends on the receiver advertising its cable addresses in time.
/// Cable and WiFi skip the race: the dial is pinned to one local interface
/// the receiver's record was actually seen on.
enum ConnectionMethod: String, CaseIterable {
    case automatic, cable, wifi

    static let defaultsKey = "connectionMethod"

    static func load(from defaults: UserDefaults = .standard) -> ConnectionMethod {
        ConnectionMethod(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .automatic
    }

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .cable: return "Cable"
        case .wifi: return "WiFi"
        }
    }

    var explanation: String {
        switch self {
        case .automatic:
            return "USB for iPhone and iPad. A Mac goes over whichever path answers first and moves onto a cable once one is found."
        case .cable:
            return "Only USB (iPhone, iPad) or a direct USB-C / Thunderbolt cable (Mac). Never falls back to WiFi."
        case .wifi:
            return "Only the network. Cables are ignored."
        }
    }

    /// Shown on a device row whose every path this method rules out.
    var unavailableNote: String {
        switch self {
        case .automatic: return ""
        case .cable: return "no cable connected"
        case .wifi: return "not on WiFi"
        }
    }

    /// usbmuxd dials (iPhone and iPad on a cable).
    var allowsUSB: Bool { self != .wifi }
    /// The probe that moves a WiFi session onto a cable (PROTOCOL.md 6.4),
    /// and the USB-unplug failover onto WiFi: both cross between paths.
    var switchesPathsOnItsOwn: Bool { self == .automatic }
    /// Connect a Mac receiver whose record just appeared on the cable.
    var connectsOnCablePlug: Bool { self != .wifi }

    /// How to dial a receiver's Bonjour service, given the local interfaces
    /// its record was seen on.
    func route(among interfaces: [RouteInterface]) -> ServiceRoute {
        guard self != .automatic else { return .anyPath }
        return candidates(among: interfaces).first.map { .pinned($0.name) } ?? .unavailable
    }

    /// The interface a pinned dial should move onto now that the receiver's
    /// record is seen on `interfaces`, or nil to stay on `pinned`. A
    /// replugged USB-C cable can come back as a different interface (en4
    /// one minute, en8 the next), and a dial scoped to the old one waits
    /// forever. A pin that still reaches the receiver stays put unless a
    /// better kind of link turned up (the real cable next to anri), so a
    /// mere change in browse order never moves a session.
    func repin(from pinned: String, among interfaces: [RouteInterface]) -> String? {
        let ranked = candidates(among: interfaces)
        guard let best = ranked.first, best.name != pinned else { return nil }
        guard let current = ranked.first(where: { $0.name == pinned }) else { return best.name }
        return rank(best) < rank(current) ? best.name : nil
    }

    /// The interfaces this method may dial over, best first.
    private func candidates(among interfaces: [RouteInterface]) -> [RouteInterface] {
        let allowed: [RouteInterface]
        switch self {
        case .automatic: return []
        // A routed wired path (a docked Mac on the office LAN) is still the
        // network, not the cable.
        case .cable: allowed = interfaces.filter(\.isDirectLink)
        case .wifi: allowed = interfaces.filter { !$0.isDirectLink }
        }
        // Stable: within a rank, the browse result's order decides.
        return allowed.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    /// Lower is better.
    private func rank(_ interface: RouteInterface) -> Int {
        switch self {
        case .automatic:
            return 0
        case .cable:
            // anri* is wired and link-local like the cable, but it is an
            // Apple-internal link next to the real one (its anpi* sibling
            // completes handshakes without carrying the stream). Only use it
            // when nothing else is there.
            return interface.name.hasPrefix("anri") ? 1 : 0
        case .wifi:
            return interface.isWiFi ? 0 : 1
        }
    }

    /// The target a device row's Connect dials: the cable first, as always,
    /// minus whatever this method rules out.
    func pick<Target>(usb: Target?, network: (target: Target, route: ServiceRoute)?) -> Target? {
        if let usb, allowsUSB { return usb }
        if let network, network.route != .unavailable { return network.target }
        return nil
    }
}

/// A local interface a receiver's Bonjour record was seen on.
struct RouteInterface: Equatable {
    let name: String
    let isWiFi: Bool
    /// The host-to-host cable (DirectCable.isDirectLink).
    let isDirectLink: Bool
}

extension RouteInterface {
    init(_ interface: NWInterface) {
        self.init(name: interface.name, isWiFi: interface.type == .wifi,
                  isDirectLink: DirectCable.isDirectLink(interface))
    }
}

enum ServiceRoute: Equatable {
    /// Let Network.framework race every resolved address (Automatic).
    case anyPath
    /// Resolve and connect over this local interface only.
    case pinned(String)
    /// The method rules out every interface the record was seen on.
    case unavailable
}

/// Why a dial pinned to the direct cable gets nowhere, for the session row.
/// A VPN that routes link-local traffic into its tunnel can also delete the
/// cable's own routes: F5's "prohibit routing table changes" removes every
/// route of an interface that comes up while the tunnel is connected, so a
/// cable plugged in (or re-enumerated) mid-session carries nothing at all,
/// IPv6 link-local included. No socket option gets past a missing route;
/// interfaces that were already up when the VPN connected keep theirs.
enum CableDialTrouble {
    /// `relayExpected`: this Mac is paired with a cable relay
    /// (CableRelay.swift), which has not connected.
    static func hint(interface: String, tunnel: String?, relayExpected: Bool = false) -> String {
        if relayExpected {
            return "No answer over the cable (\(interface)), and the cable relay on the receiver "
                + "has not connected — is it running there?"
        }
        if let tunnel {
            return "No answer over the cable (\(interface)) — the VPN on \(tunnel) blocks it. "
                + "Reconnect the VPN with the cable plugged in, or turn it off."
        }
        return "No answer over the cable (\(interface)) — is the receiver running?"
    }

    /// Tunnel interfaces as macOS names them (utun for Network Extension
    /// and most third-party VPNs, ipsec and ppp for the built-in ones).
    static func isTunnel(_ name: String) -> Bool {
        ["utun", "ipsec", "ppp"].contains { name.hasPrefix($0) }
    }

    /// The tunnel interface the system routes IPv4 link-local traffic
    /// through, nil when it stays local. Connecting an unbound UDP socket
    /// sends nothing; it only runs the route lookup, and the source address
    /// it picks names the interface.
    static func linkLocalTunnel() -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var dst = sockaddr_in()
        dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = in_port_t(9).bigEndian
        dst.sin_addr.s_addr = inet_addr("169.254.255.254")
        var src = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafePointer(to: &dst) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        } && withUnsafeMutablePointer(to: &src) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) == 0 }
        }
        guard ok else { return nil }
        return interfaceName(holding: src.sin_addr.s_addr).flatMap { isTunnel($0) ? $0 : nil }
    }

    private static func interfaceName(holding address: in_addr_t) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            if addr == address { return String(cString: ptr.pointee.ifa_name) }
        }
        return nil
    }
}
