import CryptoKit
import Compression
import Foundation

public enum SealError: Error, Equatable, LocalizedError {
    case notOpened, older

    public var errorDescription: String? {
        switch self {
        case .notOpened: "The snapshot could not be opened. The key on this phone may no longer match the server; pair the phone again."
        case .older: "The relay sent an older snapshot than the newest one already opened, so it was ignored."
        }
    }
}

public struct SlotAnswer: Codable, Sendable, Equatable {
    public var schema: Int?
    public var counter: Int
    public var madeAt: String?
    public var slotNonce: String
    public var key: String
    public var nonce: String
    public var body: String

    enum CodingKeys: String, CodingKey {
        case schema, counter, madeAt = "made_at", slotNonce = "slot_nonce", key, nonce, body
    }
}

public enum Sealing {
    public static func open(_ a: SlotAnswer, pairing p: Pairing, newest: Int? = nil) throws -> Data {
        if let newest, a.counter < newest { throw SealError.older }
        guard let phoneKey = p.keyData, phoneKey.count == 32,
              let slotNonce = Data(base64Encoded: a.slotNonce), let wrapped = Data(base64Encoded: a.key),
              let bodyNonce = Data(base64Encoded: a.nonce), let body = Data(base64Encoded: a.body)
        else { throw SealError.notOpened }
        let contentKey = try gcm(phoneKey, slotNonce, wrapped, "dokkit-phone-v1|\(p.mailbox)|\(p.slot)|\(a.counter)")
        guard contentKey.count == 32 else { throw SealError.notOpened }
        let zipped = try gcm(contentKey, bodyNonce, body, "dokkit-phone-v1|\(p.mailbox)|body|\(a.counter)")
        guard let json = Gzip.inflate(zipped) else { throw SealError.notOpened }
        return json
    }

    private static func gcm(_ key: Data, _ nonce: Data, _ sealed: Data, _ aad: String) throws -> Data {
        guard sealed.count > 16 else { throw SealError.notOpened }
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: nonce), ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(aad.utf8))
        } catch { throw SealError.notOpened }
    }
}

enum Gzip {
    static func inflate(_ d: Data, limit: Int = 64 << 20) -> Data? {
        let b = [UInt8](d)
        guard b.count >= 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 4 != 0 {
            guard i + 2 <= b.count else { return nil }
            i += 2 + Int(b[i]) + (Int(b[i + 1]) << 8)
        }
        for bit: UInt8 in [8, 16] where flags & bit != 0 {
            while i < b.count, b[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 2 != 0 { i += 2 }
        guard i < b.count - 8 else { return nil }
        let raw = Array(b[i..<(b.count - 8)])
        let word = { (at: Int) in (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[b.count - 8 + at + $1]) << UInt32(8 * $1) } }
        var cap = max(raw.count * 8, 4096)
        while cap <= limit {
            var out = [UInt8](repeating: 0, count: cap)
            let n = compression_decode_buffer(&out, cap, raw, raw.count, nil, COMPRESSION_ZLIB)
            if n == 0 { return nil }
            if n < cap {
                out.removeSubrange(n...)
                return word(0) == CRC32.sum(out) && word(4) == UInt32(truncatingIfNeeded: n) ? Data(out) : nil
            }
            cap *= 4
        }
        return nil
    }
}
