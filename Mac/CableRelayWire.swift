// Compiled into the Mac sender and into the relay helper (tools/odrelay).

import CryptoKit
import Foundation

/// The reverse relay's own wire, spoken before the OpenDisplay stream.
///
/// Some VPN clients (F5 with "prohibit routing table changes") drop every
/// connection the sender opens over the direct cable, yet let the other Mac
/// connect in. So the relay on the receiver Mac dials the sender's relay
/// listener over the cable, and the sender uses that socket as if it had
/// dialed the receiver. Every message has a fixed length, so neither end
/// ever reads into the stream that follows:
///
///     sender → relay   "ODRELAY 1 <32 hex nonce>\n"         43 bytes, on accept
///     relay  → sender  "<64 hex HMAC-SHA256(token, nonce)>\n" 65 bytes
///     sender → relay   "GO\n"   the sender wants the session now
///     relay  → sender  "OK\n"   the relay reached the receiver on
///                               127.0.0.1:9000; from here on both ends
///                               just pipe the OpenDisplay byte stream
///
/// The token is a secret written to both Macs at install, so the sender
/// only takes a relay it was paired with.
enum CableRelayWire {
    /// Advertised by the sender, on the cable interfaces only.
    static let serviceType = "_odrelay._tcp"
    /// The listener's fixed port, for a relay that finds the sender without
    /// Bonjour (its neighbour table).
    static let port: UInt16 = 9010
    static let challengePrefix = "ODRELAY 1 "
    static let nonceLength = 16
    static let challengeLength = challengePrefix.utf8.count + nonceLength * 2 + 1
    static let responseLength = 65
    static let go = Data("GO\n".utf8)
    static let ok = Data("OK\n".utf8)

    static func makeNonce() -> Data {
        Data(SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) })
    }

    /// A fresh pairing secret: 32 random bytes as 64 lowercase hex digits.
    static func makeToken() -> String {
        hex(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    static func challenge(nonce: Data) -> Data {
        Data((challengePrefix + hex(nonce) + "\n").utf8)
    }

    /// The nonce a well-formed challenge carries.
    static func nonce(fromChallenge data: Data) -> Data? {
        guard data.count == challengeLength,
              let text = String(data: data, encoding: .utf8),
              text.hasPrefix(challengePrefix), text.hasSuffix("\n") else { return nil }
        let digits = text.dropFirst(challengePrefix.count).dropLast()
        guard let nonce = bytes(fromHex: String(digits)), nonce.count == nonceLength else { return nil }
        return nonce
    }

    static func response(token: String, nonce: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: nonce, using: SymmetricKey(data: Data(token.utf8)))
        return Data((hex(Data(mac)) + "\n").utf8)
    }

    static func verify(response data: Data, token: String, nonce: Data) -> Bool {
        guard data.count == responseLength, data.last == UInt8(ascii: "\n"),
              let text = String(data: data.dropLast(), encoding: .utf8),
              let mac = bytes(fromHex: text) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            mac, authenticating: nonce, using: SymmetricKey(data: Data(token.utf8)))
    }

    /// Where both Macs keep the token.
    static var defaultTokenURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenDisplayRelay/token")
    }

    /// The token in `url`, nil when the file is missing or malformed (the
    /// relay is then simply off).
    static func loadToken(from url: URL = defaultTokenURL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return validToken(text)
    }

    static func validToken(_ text: String) -> String? {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard token.count == 64, bytes(fromHex: token) != nil else { return nil }
        return token
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func bytes(fromHex text: String) -> Data? {
        guard text.count.isMultiple(of: 2), text.allSatisfy(\.isHexDigit) else { return nil }
        var out = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}
