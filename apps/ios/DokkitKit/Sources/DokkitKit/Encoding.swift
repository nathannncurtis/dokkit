import Foundation

enum Base64 {
    static func url(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        t += String(repeating: "=", count: (4 - t.count % 4) % 4)
        return Data(base64Encoded: t)
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
    }

    static func sum<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        ~bytes.reduce(~UInt32(0)) { table[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }
}

public enum KeyCheck {
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)

    public static func isValid(_ key: String, prefix: String) -> Bool {
        guard key.hasPrefix(prefix) else { return false }
        let rest = Array(key.utf8.dropFirst(prefix.utf8.count))
        guard rest.count == 36, rest.allSatisfy(alphabet.contains) else { return false }
        var n = CRC32.sum(rest[..<30])
        var tail = [UInt8](repeating: alphabet[0], count: 6)
        for i in stride(from: 5, through: 0, by: -1) {
            tail[i] = alphabet[Int(n % 62)]
            n /= 62
        }
        return Array(rest[30...]) == tail
    }
}

func isLowerHex32(_ s: String) -> Bool {
    s.utf8.count == 32 && s.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
}
