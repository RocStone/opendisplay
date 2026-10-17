import Darwin
import dnssd
import Foundation
import Network

/// The sender's end of the reverse relay (CableRelayWire, tools/odrelay).
/// In the Cable connection method it listens on the direct cable's
/// link-local addresses, never on a wildcard, and advertises the relay
/// service there. The relay on the receiver Mac keeps one connection open
/// to it; a session whose direct dial gets nowhere takes that socket and
/// uses it as its transport.
final class CableRelayHub {
    let token: String
    /// A relay connected and waits to be used.
    var onArrival: (@MainActor () -> Void)?

    private let queue = DispatchQueue(label: "sender.relay")
    private var monitor: NWPathMonitor?
    private var refreshTimer: DispatchSourceTimer?
    private var listeners: [String: Listening] = [:]
    // Interfaces where the fixed port was taken: listen on any port there,
    // the Bonjour record carries it.
    private var anyPortOn: Set<String> = []
    // The Bonjour records, one per cable interface. Registered through
    // dns_sd with the interface index: NWListener.Service would advertise
    // on every interface, WiFi included, and scoping the listener itself
    // takes an NWInterface, which a VPN keeps us from getting (refresh).
    private var adverts: [String: DNSServiceRef] = [:]
    // Accepted relay sockets, oldest first. Deliberately not started: an
    // NWConnection calls back on the queue it was started on, and the
    // session that takes one keeps all its connection state on its own
    // queue. The pairing check runs there too (activate), before a single
    // stream byte flows.
    private var waiting: [Waiting] = []
    private static let maxWaiting = 4

    private struct Listening {
        let address: String
        let listener: NWListener
    }

    private struct Waiting {
        let interface: String
        let connection: NWConnection
    }

    init(token: String) {
        self.token = token
    }

    func start() {
        queue.async { [self] in
            guard monitor == nil else { return }
            Log.info("cable relay: on")
            // Only a trigger: with a VPN connected the path lists the tunnel
            // and WiFi, never the cable (DirectCable.directLinkNames).
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] _ in self?.refresh() }
            monitor.start(queue: queue)
            self.monitor = monitor
            // A link-local address can come up after its interface did,
            // without a path update.
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in self?.refresh() }
            timer.resume()
            refreshTimer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            guard monitor != nil else { return }
            Log.info("cable relay: off")
            monitor?.cancel()
            monitor = nil
            refreshTimer?.cancel()
            refreshTimer = nil
            listeners.values.forEach { $0.listener.cancel() }
            listeners.removeAll()
            adverts.values.forEach(DNSServiceRefDeallocate)
            adverts.removeAll()
            waiting.forEach { $0.connection.cancel() }
            waiting.removeAll()
        }
    }

    /// The newest waiting relay socket, not yet started; nil when none.
    func take() -> (connection: NWConnection, interface: String)? {
        queue.sync {
            guard let last = waiting.popLast() else { return nil }
            return (last.connection, last.interface)
        }
    }

    var hasWaiting: Bool { queue.sync { !waiting.isEmpty } }

    private func refresh() {
        var wanted: [String: String] = [:]
        for name in DirectCable.directLinkNames() {
            wanted[name] = Self.linkLocalIPv6(of: name)
        }
        for (name, listening) in listeners where wanted[name] != listening.address {
            Log.info("cable relay: stopped listening on \(name)")
            listening.listener.cancel()
            listeners[name] = nil
            withdraw(on: name)
        }
        for (name, address) in wanted where listeners[name] == nil {
            listen(on: name, address: address)
        }
        // A socket on an interface that went away is dead.
        waiting.removeAll { entry in
            guard wanted[entry.interface] == nil else { return false }
            entry.connection.cancel()
            return true
        }
    }

    private func listen(on name: String, address: String) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        // An idle relay socket must not outlive an unplug for long.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .interactiveVideo
        params.allowLocalEndpointReuse = true
        // The scoped address keeps it to the one interface.
        let port = anyPortOn.contains(name) ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: CableRelayWire.port)!
        guard let host = IPv6Address("\(address)%\(name)") else { return }
        params.requiredLocalEndpoint = .hostPort(host: .ipv6(host), port: port)
        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            Log.info("cable relay: cannot listen on \(name): \(error)")
            return
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                let port = listener.port?.rawValue ?? 0
                Log.info("cable relay: listening on \(name) port \(port)")
                self.advertise(on: name, port: port)
            case .failed(let error):
                Log.info("cable relay: listener on \(name) failed: \(error)")
                if case .posix(.EADDRINUSE) = error { self.anyPortOn.insert(name) }
                self.withdraw(on: name)
                listener.cancel()
                // The next refresh listens again.
                if self.listeners[name]?.listener === listener { self.listeners[name] = nil }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, on: name)
        }
        listener.start(queue: queue)
        listeners[name] = Listening(address: address, listener: listener)
    }

    /// Without a record the relay still finds us: it also tries every
    /// neighbour on the cable at the fixed port.
    private func advertise(on name: String, port: UInt16) {
        withdraw(on: name)
        var ref: DNSServiceRef?
        let error = DNSServiceRegister(&ref, 0, if_nametoindex(name), nil, CableRelayWire.serviceType,
                                       nil, nil, port.bigEndian, 0, nil, nil, nil)
        guard error == kDNSServiceErr_NoError, let ref else {
            return Log.info("cable relay: cannot advertise on \(name) (dns_sd \(error))")
        }
        DNSServiceSetDispatchQueue(ref, queue)
        adverts[name] = ref
    }

    private func withdraw(on name: String) {
        if let ref = adverts.removeValue(forKey: name) { DNSServiceRefDeallocate(ref) }
    }

    private func accept(_ connection: NWConnection, on interface: String) {
        Log.info("cable relay: relay connected over \(interface) from \(connection.endpoint)")
        waiting.append(Waiting(interface: interface, connection: connection))
        while waiting.count > Self.maxWaiting {
            waiting.removeFirst().connection.cancel()
        }
        Task { @MainActor [weak self] in self?.onArrival?() }
    }

    /// The interface's own link-local IPv6 address, scope stripped.
    private static func linkLocalIPv6(of name: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard String(cString: ifa.ifa_name) == name, let sa = ifa.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in6>.size), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(String(cString: host).split(separator: "%").first ?? "")
            if let v6 = IPv6Address(address), v6.isLinkLocal { return address }
        }
        return nil
    }

    /// Start a taken relay socket on `queue` and run the pairing check and
    /// the GO/OK exchange. `done(true)` once the relay has reached the
    /// receiver: the socket is then exactly what a direct dial would have
    /// produced, ready, with the receiver's hello as the next bytes.
    /// Calls back on `queue`; on failure the socket is already cancelled.
    static func activate(_ connection: NWConnection, token: String, queue: DispatchQueue,
                         timeout: TimeInterval = 4, done: @escaping (Bool) -> Void) {
        var finished = false
        func finish(_ ok: Bool, _ problem: String = "") {
            guard !finished else { return }
            finished = true
            connection.stateUpdateHandler = nil
            if !ok {
                Log.info("cable relay: \(problem)")
                connection.cancel()
            }
            done(ok)
        }
        func receive(_ length: Int, _ next: @escaping (Data) -> Void) {
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, error in
                guard let data, data.count == length, error == nil else {
                    return finish(false, "relay closed during the handshake"
                                  + (error.map { " (\($0))" } ?? ""))
                }
                next(data)
            }
        }
        let nonce = CableRelayWire.makeNonce()
        queue.asyncAfter(deadline: .now() + timeout) { finish(false, "relay did not answer in time") }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: CableRelayWire.challenge(nonce: nonce), completion: .idempotent)
                receive(CableRelayWire.responseLength) { response in
                    guard CableRelayWire.verify(response: response, token: token, nonce: nonce) else {
                        return finish(false, "rejected a relay that is not paired with this Mac")
                    }
                    connection.send(content: CableRelayWire.go, completion: .idempotent)
                    receive(CableRelayWire.ok.count) { reply in
                        guard reply == CableRelayWire.ok else {
                            return finish(false, "relay sent no OK")
                        }
                        finish(true)
                    }
                }
            case .failed(let error), .waiting(let error):
                finish(false, "relay socket failed: \(error)")
            case .cancelled:
                finish(false, "relay socket cancelled")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
}
