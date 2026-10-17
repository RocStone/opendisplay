import Foundation
import Network

/// One cable connection of the relay helper, from dial to close
/// (CableRelayWire): stand by for as long as it takes until the sender
/// sends its challenge, answer it, and on GO open the receiver on loopback,
/// say OK and pipe both ways. Ends on the first close or error on either
/// side; the helper then dials again.
final class RelayLink {
    private let cable: NWConnection
    private let token: String
    private let receiverEndpoint: NWEndpoint
    private let queue: DispatchQueue
    private let log: (String) -> Void
    private var receiver: NWConnection?
    private var onEnd: ((_ reason: String, _ carried: Bool) -> Void)?
    /// A session ran over this link: the sender took it and the receiver
    /// answered.
    private var carried = false
    private var connected = false

    init(cable: NWConnection, token: String, receiver: NWEndpoint,
         queue: DispatchQueue, log: @escaping (String) -> Void) {
        self.cable = cable
        self.token = token
        self.receiverEndpoint = receiver
        self.queue = queue
        self.log = log
    }

    /// `onConnected` once the cable socket is up (the sender accepted it),
    /// `onEnd` exactly once, with whether a session ran over the link.
    func start(onConnected: @escaping () -> Void,
               onEnd: @escaping (_ reason: String, _ carried: Bool) -> Void) {
        self.onEnd = onEnd
        cable.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.connected = true
                onConnected()
                self.awaitChallenge()
            case .waiting(let error):
                // A fresh process's first dial often waits a moment ("network
                // is down") before it goes out; the caller's deadline covers
                // a dial that never does.
                if self.connected { return self.end("cable socket: \(error)") }
                if #available(macOS 14, *), self.cable.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    self.log("macOS denies this helper the local network — "
                             + "run tools/odrelay/install.sh again from the sender Mac")
                    self.end("local network denied")
                }
            case .failed(let error):
                self.end("cable socket: \(error)")
            case .cancelled:
                self.end("cable socket cancelled")
            default:
                break
            }
        }
        // An unplugged cable sends nothing, not even a reset.
        cable.viabilityUpdateHandler = { [weak self] viable in
            if !viable { self?.end("cable path no longer viable") }
        }
        cable.start(queue: queue)
    }

    func cancel() {
        end("cancelled")
    }

    private func awaitChallenge() {
        receive(CableRelayWire.challengeLength) { [weak self] challenge in
            guard let self else { return }
            guard let nonce = CableRelayWire.nonce(fromChallenge: challenge) else {
                return self.end("the listener is not an OpenDisplay sender")
            }
            self.cable.send(content: CableRelayWire.response(token: self.token, nonce: nonce),
                            completion: .idempotent)
            self.receive(CableRelayWire.go.count) { [weak self] go in
                guard let self else { return }
                guard go == CableRelayWire.go else {
                    return self.end("the sender refused the pairing")
                }
                self.openReceiver()
            }
        }
    }

    private func openReceiver() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .interactiveVideo
        let receiver = NWConnection(to: receiverEndpoint, using: params)
        self.receiver = receiver
        queue.asyncAfter(deadline: .now() + 3) { [weak self, weak receiver] in
            guard let self, let receiver, receiver.state != .ready else { return }
            self.end("receiver did not answer on \(self.receiverEndpoint)")
        }
        receiver.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.carried = true
                self.log("session started")
                self.cable.send(content: CableRelayWire.ok, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error { return self.end("cable send: \(error)") }
                    self.pump(from: self.cable, to: receiver, names: ("sender", "receiver"))
                    self.pump(from: receiver, to: self.cable, names: ("receiver", "sender"))
                })
            case .failed(let error), .waiting(let error):
                self.end("receiver: \(error)")
            case .cancelled:
                self.end("receiver socket cancelled")
            default:
                break
            }
        }
        receiver.start(queue: queue)
    }

    /// Copy `from` into `to`, one read in flight and the next read only
    /// after the write drained, so a slow side pushes back on the other.
    private func pump(from: NWConnection, to: NWConnection, names: (from: String, to: String)) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    if let sendError { return self.end("send to the \(names.to): \(sendError)") }
                    if isComplete { return self.end("the \(names.from) closed") }
                    self.pump(from: from, to: to, names: names)
                })
            } else if let error {
                self.end("the \(names.from): \(error)")
            } else {
                self.end("the \(names.from) closed")
            }
        }
    }

    private func receive(_ length: Int, _ next: @escaping (Data) -> Void) {
        cable.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self else { return }
            guard let data, data.count == length, error == nil else {
                return self.end(error.map { "cable socket: \($0)" } ?? "the sender closed")
            }
            next(data)
        }
    }

    private func end(_ reason: String) {
        guard let onEnd else { return }
        self.onEnd = nil
        cable.stateUpdateHandler = nil
        cable.viabilityUpdateHandler = nil
        cable.cancel()
        receiver?.stateUpdateHandler = nil
        receiver?.cancel()
        onEnd(reason, carried)
    }
}
