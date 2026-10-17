// odrelay: the receiver Mac's half of the OpenDisplay reverse relay.
// See README.md next to this file.

import Foundation
import Network

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: odrelay [--token-file PATH] [--receiver-port PORT] [--verbose]
           odrelay --prime

    Keeps a connection open over the direct cable to the OpenDisplay sender's
    relay listener and pipes it to the receiver on 127.0.0.1 (default 9000).
    --prime touches the local network once and exits (install.sh runs it).

    """.utf8))
    exit(64)
}

var tokenURL = CableRelayWire.defaultTokenURL
var receiverPort: UInt16 = 9000
var verbose = false
var prime = false
var arguments = CommandLine.arguments.dropFirst()
while let flag = arguments.popFirst() {
    switch flag {
    case "--token-file":
        guard let path = arguments.popFirst() else { usage() }
        tokenURL = URL(fileURLWithPath: path)
    case "--receiver-port":
        guard let text = arguments.popFirst(), let port = UInt16(text) else { usage() }
        receiverPort = port
    case "--verbose":
        verbose = true
    case "--prime":
        prime = true
    default:
        usage()
    }
}

/// Timestamped lines on stderr (launchd writes them to the log file). A
/// line equal to the previous one is dropped, so a sender that stays away
/// costs one line, not one every few seconds.
var lastLine = ""
func log(_ line: String) {
    guard line != lastLine else { return }
    lastLine = line
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                            formatOptions: [.withInternetDateTime])
    FileHandle.standardError.write(Data("\(stamp) \(line)\n".utf8))
}

// macOS asks before a process reaches the local network, and a LaunchAgent
// has no way to ask: run from launchd, an unknown binary gets "local
// network prohibited". Run once from an ssh session (allowed there), the
// same binary at the same path is allowed from launchd too. So install.sh
// runs this after every install: one dial toward a link-local address and a
// Bonjour browse, the two kinds of access the helper needs.
if prime {
    let queue = DispatchQueue(label: "odrelay.prime")
    let scope = DirectCable.directLinkNames().first ?? "en0"
    let probe = NWConnection(host: NWEndpoint.Host("fe80::1%\(scope)"), port: 9, using: .tcp)
    probe.start(queue: queue)
    let browser = NWBrowser(for: .bonjour(type: CableRelayWire.serviceType, domain: nil), using: .tcp)
    browser.start(queue: queue)
    queue.asyncAfter(deadline: .now() + 2) {
        print("local network touched over \(scope)")
        exit(0)
    }
    dispatchMain()
}

guard let token = CableRelayWire.loadToken(from: tokenURL) else {
    log("no valid token in \(tokenURL.path)")
    exit(78)
}

final class Relay {
    private let token: String
    private let receiver: NWEndpoint
    private let queue = DispatchQueue(label: "odrelay")
    private let browser = NWBrowser(for: .bonjour(type: CableRelayWire.serviceType, domain: nil),
                                    using: .tcp)
    private var results: Set<NWBrowser.Result> = []
    private var link: RelayLink?
    private var backoff: TimeInterval = 0.5
    // The sender's record changed while a dial round was under way.
    private var resultsChanged = false
    // Bumped by every scheduled attempt; a stale timer does nothing.
    private var attemptGeneration = 0

    init(token: String, receiverPort: UInt16) {
        self.token = token
        receiver = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: receiverPort)!)
    }

    func run() {
        log("started; receiver at \(receiver)")
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            self.results = results
            // A sender that just appeared need not wait out the backoff.
            if self.link == nil { self.schedule(after: 0.2) } else { self.resultsChanged = true }
        }
        browser.start(queue: queue)
        schedule(after: 0.5)
    }

    private func schedule(after delay: TimeInterval) {
        attemptGeneration += 1
        let generation = attemptGeneration
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.attemptGeneration, self.link == nil else { return }
            self.dial(self.candidates()[...])
        }
    }

    /// Where the sender's relay listener may be, over cable interfaces
    /// only: every neighbour on the cable at the fixed port first (a literal
    /// answers or refuses at once), then its Bonjour records (resolving can
    /// take seconds, and a sender may have had to take another port).
    private typealias Candidate = (endpoint: NWEndpoint, name: String, interface: NWInterface?)

    private func candidates() -> [Candidate] {
        var out: [Candidate] = []
        // A scoped literal needs no NWInterface: path monitors may not list
        // the cable at all (a VPN on this Mac).
        let cable = DirectCable.directLinkNames()
        for (address, name) in Self.neighbours() where cable.contains(name) {
            guard let host = IPv6Address("\(address)%\(name)") else { continue }
            out.append((.hostPort(host: .ipv6(host), port: NWEndpoint.Port(rawValue: CableRelayWire.port)!),
                        name, nil))
        }
        for result in results {
            guard case .service(let name, let type, let domain, _) = result.endpoint else { continue }
            for interface in result.interfaces where DirectCable.isDirectLink(interface) {
                out.append((.service(name: name, type: type, domain: domain, interface: interface),
                            interface.name, interface))
            }
        }
        return out
    }

    private func dial(_ remaining: ArraySlice<Candidate>) {
        guard let (endpoint, name, interface) = remaining.first else {
            if resultsChanged {
                resultsChanged = false
                return schedule(after: 0.2)
            }
            log("no sender reachable over the cable — retrying")
            backoff = min(backoff * 2, 2)
            return schedule(after: backoff)
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        params.requiredInterface = interface
        params.serviceClass = .interactiveVideo
        let link = RelayLink(cable: NWConnection(to: endpoint, using: params), token: token,
                             receiver: receiver, queue: queue, log: log)
        self.link = link
        if verbose { log("dialing \(endpoint)") }
        var connected = false
        var connectedAt = Date()
        link.start(onConnected: {
            connected = true
            connectedAt = Date()
            self.resultsChanged = false
            log("connected to the sender over \(name), standing by")
        }, onEnd: { [weak self] reason, carried in
            guard let self, self.link === link else { return }
            self.link = nil
            guard connected else {
                if verbose { log("  \(endpoint): \(reason)") }
                return self.dial(remaining.dropFirst())
            }
            log("link ended: \(reason)")
            // A link that carried a session ended because the session did:
            // the sender wants the next one at once. One that ended soon
            // without a session (the receiver is not running) must not
            // turn into a reconnect loop.
            if carried {
                self.backoff = 0.3
            } else if Date().timeIntervalSince(connectedAt) > 10 {
                self.backoff = 1
            } else {
                self.backoff = min(self.backoff * 2, 2)
            }
            self.schedule(after: self.backoff)
        })
        queue.asyncAfter(deadline: .now() + 4) {
            if !connected { link.cancel() }
        }
    }

    /// (address, interface) of every IPv6 neighbour, own addresses left
    /// out (ndp lists those as permanent).
    private static func neighbours() -> [(String, String)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ndp")
        process.arguments = ["-an"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output.split(separator: "\n").dropFirst().compactMap { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4, fields[3] != "permanent",
                  let address = fields[0].split(separator: "%").first,
                  address.lowercased().hasPrefix("fe80:") else { return nil }
            return (String(address), String(fields[2]))
        }
    }
}

let relay = Relay(token: token, receiverPort: receiverPort)
relay.run()
dispatchMain()
