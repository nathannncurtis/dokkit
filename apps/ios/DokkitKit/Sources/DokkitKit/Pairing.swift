import Foundation

public enum PairingError: Error, Equatable, LocalizedError {
    case notACode, newerVersion, damaged, relayNotHTTPS, badToken, badKey

    public var errorDescription: String? {
        switch self {
        case .notACode: "This is not a Dokkit pairing code."
        case .newerVersion: "This code is from a newer Dokkit than this app understands."
        case .damaged: "The pairing code is damaged. Show a new one in Settings, Phones."
        case .relayNotHTTPS: "The relay address in this code is not https, so the app refuses it."
        case .badToken: "The fetch token in this code does not pass its checksum."
        case .badKey: "The phone key in this code is not valid."
        }
    }
}

public struct Pairing: Codable, Sendable, Equatable {
    public var relay: String
    public var mailbox: String
    public var slot: String
    public var token: String
    public var key: String
    public var name: String

    public init(relay: String, mailbox: String, slot: String, token: String, key: String, name: String) {
        (self.relay, self.mailbox, self.slot, self.token, self.key, self.name) = (relay, mailbox, slot, token, key, name)
    }

    public var keyData: Data? { Data(base64Encoded: key) }

    public static func parse(_ text: String) throws -> Pairing {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("dokkit-phone:") else { throw PairingError.notACode }
        guard t.hasPrefix("dokkit-phone:1:") else { throw PairingError.newerVersion }
        guard let json = Base64.url(String(t.dropFirst("dokkit-phone:1:".count))),
              let p = try? JSONDecoder().decode(Pairing.self, from: json),
              isLowerHex32(p.mailbox), isLowerHex32(p.slot)
        else { throw PairingError.damaged }
        guard let url = URL(string: p.relay), let host = url.host, !host.isEmpty else { throw PairingError.damaged }
        guard url.scheme?.lowercased() == "https" else { throw PairingError.relayNotHTTPS }
        guard KeyCheck.isValid(p.token, prefix: "dkf_") else { throw PairingError.badToken }
        guard p.keyData?.count == 32 else { throw PairingError.badKey }
        return p
    }
}
