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
        switch self {
        case .automatic:
            return .anyPath
        case .cable:
            // anri* is wired and link-local like the cable, but it is an
            // Apple-internal link next to the real one (its anpi* sibling
            // completes handshakes without carrying the stream). Only use it
            // when nothing else is there.
            let links = interfaces.filter(\.isDirectLink)
            let pick = links.first { !$0.name.hasPrefix("anri") } ?? links.first
            return pick.map { .pinned($0.name) } ?? .unavailable
        case .wifi:
            // Anything but the cable, WiFi first. A routed wired path (a
            // docked Mac on the office LAN) is still the network.
            let network = interfaces.filter { !$0.isDirectLink }
            let pick = network.first(where: \.isWiFi) ?? network.first
            return pick.map { .pinned($0.name) } ?? .unavailable
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
