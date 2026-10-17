import Network
import XCTest

final class CableRelayWireTests: XCTestCase {
    private let token = String(repeating: "ab", count: 32)

    func testChallengeCarriesItsNonce() {
        let nonce = CableRelayWire.makeNonce()
        let challenge = CableRelayWire.challenge(nonce: nonce)
        XCTAssertEqual(challenge.count, CableRelayWire.challengeLength)
        XCTAssertEqual(CableRelayWire.nonce(fromChallenge: challenge), nonce)
    }

    func testMalformedChallengesAreRefused() {
        let good = CableRelayWire.challenge(nonce: CableRelayWire.makeNonce())
        XCTAssertNil(CableRelayWire.nonce(fromChallenge: good.dropLast()))
        XCTAssertNil(CableRelayWire.nonce(fromChallenge: Data("HTTP/1.1 200 OK\r\n".utf8)))
        var wrongVersion = good
        wrongVersion[8] = UInt8(ascii: "2")
        XCTAssertNil(CableRelayWire.nonce(fromChallenge: wrongVersion))
        var notHex = good
        notHex[12] = UInt8(ascii: "z")
        XCTAssertNil(CableRelayWire.nonce(fromChallenge: notHex))
    }

    func testOnlyThePairedTokenAnswersTheChallenge() {
        let nonce = CableRelayWire.makeNonce()
        let response = CableRelayWire.response(token: token, nonce: nonce)
        XCTAssertEqual(response.count, CableRelayWire.responseLength)
        XCTAssertTrue(CableRelayWire.verify(response: response, token: token, nonce: nonce))
        let stranger = CableRelayWire.response(token: String(repeating: "cd", count: 32), nonce: nonce)
        XCTAssertFalse(CableRelayWire.verify(response: stranger, token: token, nonce: nonce))
        // An answer to another nonce is a replay.
        XCTAssertFalse(CableRelayWire.verify(response: response, token: token,
                                             nonce: CableRelayWire.makeNonce()))
        XCTAssertFalse(CableRelayWire.verify(response: response.dropLast(), token: token, nonce: nonce))
    }

    func testTokens() {
        let fresh = CableRelayWire.makeToken()
        XCTAssertEqual(CableRelayWire.validToken(fresh), fresh)
        XCTAssertNotEqual(CableRelayWire.makeToken(), fresh)
        XCTAssertEqual(CableRelayWire.validToken("  \(fresh.uppercased())\n"), fresh)
        XCTAssertNil(CableRelayWire.validToken(String(fresh.dropLast())))
        XCTAssertNil(CableRelayWire.validToken(String(fresh.dropLast()) + "g"))
        XCTAssertNil(CableRelayWire.validToken(""))
    }

    func testMissingTokenFileMeansNoRelay() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertNil(CableRelayWire.loadToken(from: url))
    }
}

/// The relay helper's link (tools/odrelay) against the sender's handshake
/// over loopback: a listener stands in for the sender's cable listener, a
/// second one for the receiver.
final class CableRelayLinkTests: XCTestCase {
    private let token = CableRelayWire.makeToken()
    private let queue = DispatchQueue(label: "test.relay")
    private var listeners: [NWListener] = []
    private var links: [RelayLink] = []

    override func tearDown() {
        listeners.forEach { $0.cancel() }
        links.forEach { $0.cancel() }
        super.tearDown()
    }

    private func listen(_ accepted: @escaping (NWConnection) -> Void) throws -> NWEndpoint.Port {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = accepted
        listener.start(queue: queue)
        listeners.append(listener)
        wait(for: [ready], timeout: 5)
        return listener.port!
    }

    /// A receiver that greets every connection and echoes what it gets.
    private func fakeReceiver(connected: XCTestExpectation? = nil) throws -> NWEndpoint.Port {
        try listen { [queue] conn in
            connected?.fulfill()
            conn.start(queue: queue)
            conn.send(content: Data("HELLO".utf8), completion: .idempotent)
            func echo() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, done, _ in
                    guard let data, !done else { return }
                    conn.send(content: data, completion: .idempotent)
                    echo()
                }
            }
            echo()
        }
    }

    /// Start a relay link from `linkToken` toward a stand-in sender and
    /// return the sender's accepted, unstarted socket.
    private func relaySocket(linkToken: String, receiverPort: NWEndpoint.Port) throws -> NWConnection {
        var accepted: NWConnection?
        let arrived = expectation(description: "relay connected")
        let senderPort = try listen { conn in
            accepted = conn
            arrived.fulfill()
        }
        let link = RelayLink(
            cable: NWConnection(host: .ipv4(.loopback), port: senderPort, using: .tcp),
            token: linkToken,
            receiver: .hostPort(host: .ipv4(.loopback), port: receiverPort),
            queue: queue, log: { _ in })
        links.append(link)
        link.start(onConnected: {}, onEnd: { _, _ in })
        wait(for: [arrived], timeout: 5)
        return try XCTUnwrap(accepted)
    }

    private func read(_ conn: NWConnection, _ length: Int) -> Data? {
        var result: Data?
        let got = expectation(description: "read \(length)")
        conn.receive(minimumIncompleteLength: length, maximumLength: length) { data, _, _, _ in
            result = data
            got.fulfill()
        }
        wait(for: [got], timeout: 5)
        return result
    }

    func testPairedRelayCarriesTheStreamBothWays() throws {
        let receiverPort = try fakeReceiver()
        let socket = try relaySocket(linkToken: token, receiverPort: receiverPort)
        // A relay socket may wait a long time before a session takes it.
        Thread.sleep(forTimeInterval: 0.3)
        let activated = expectation(description: "activated")
        var ok = false
        CableRelayHub.activate(socket, token: token, queue: queue) {
            ok = $0
            activated.fulfill()
        }
        wait(for: [activated], timeout: 5)
        XCTAssertTrue(ok)
        // The receiver's first bytes come next, nothing of the handshake.
        XCTAssertEqual(read(socket, 5), Data("HELLO".utf8))
        socket.send(content: Data("ping".utf8), completion: .idempotent)
        XCTAssertEqual(read(socket, 4), Data("ping".utf8))
    }

    func testUnpairedRelayNeverReachesTheReceiver() throws {
        let connected = expectation(description: "receiver dialed")
        connected.isInverted = true
        let receiverPort = try fakeReceiver(connected: connected)
        let socket = try relaySocket(linkToken: CableRelayWire.makeToken(), receiverPort: receiverPort)
        let activated = expectation(description: "activated")
        var ok = true
        CableRelayHub.activate(socket, token: token, queue: queue) {
            ok = $0
            activated.fulfill()
        }
        wait(for: [activated, connected], timeout: 1)
        XCTAssertFalse(ok)
    }

    func testRelayWithoutAReceiverFailsTheClaim() throws {
        // A port nobody listens on: bind, note it, close.
        let gone = try listen { _ in }
        listeners.removeLast().cancel()
        let socket = try relaySocket(linkToken: token, receiverPort: gone)
        let activated = expectation(description: "activated")
        var ok = true
        CableRelayHub.activate(socket, token: token, queue: queue) {
            ok = $0
            activated.fulfill()
        }
        wait(for: [activated], timeout: 5)
        XCTAssertFalse(ok)
    }
}
