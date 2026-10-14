import Foundation
@testable import DokkitKit

struct SealingTests {
    let f = Fixtures.sealing

    func opensEveryPhonesAnswer() async throws {
        for p in f.phones {
            let json = try Sealing.open(p.slotAnswer, pairing: p.pairing)
            try await expect(String(decoding: json, as: UTF8.self) == f.snapshotJson, "\(p.name)")
        }
    }

    func parsesEveryPairingCode() async throws {
        for p in f.phones { try await expect(try Pairing.parse(p.pairingCode) == p.pairing) }
        try await expect(try Pairing.parse("  \(f.phones[0].pairingCode)\n") == f.phones[0].pairing)
    }

    func refusesBadPairingCodes() async throws {
        let good = f.phones[0].pairingCode
        await expectThrows(PairingError.notACode) { try Pairing.parse("https://example.com") }
        await expectThrows(PairingError.newerVersion) { try Pairing.parse(good.replacingOccurrences(of: ":1:", with: ":2:")) }
        await expectThrows(PairingError.damaged) { try Pairing.parse(good + "!!") }
        func code(_ edit: (inout Pairing) -> Void) -> String {
            var p = f.phones[0].pairing
            edit(&p)
            let json = try! JSONEncoder().encode(p)
            let b64 = json.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return "dokkit-phone:1:" + b64
        }
        await expectThrows(PairingError.relayNotHTTPS) { try Pairing.parse(code { $0.relay = "http://relay.example.com" }) }
        await expectThrows(PairingError.badToken) { try Pairing.parse(code { $0.token.removeLast(); $0.token += "0" }) }
        await expectThrows(PairingError.badKey) { try Pairing.parse(code { $0.key = "AAAA" }) }
        await expectThrows(PairingError.damaged) { try Pairing.parse(code { $0.slot = "xyz" }) }
    }

    func checksum() async throws {
        try await expect(KeyCheck.isValid(f.uploadKey, prefix: "dkr_"))
        for p in f.phones { try await expect(KeyCheck.isValid(p.token, prefix: "dkf_")) }
        try await expect(!KeyCheck.isValid(f.uploadKey, prefix: "dkf_"))
        for key in [f.uploadKey, f.phones[0].token] {
            var bad = key
            bad.removeLast()
            bad += key.last == "0" ? "1" : "0"
            try await expect(!KeyCheck.isValid(bad, prefix: String(key.prefix(4))))
            var body = Array(key)
            body[6] = body[6] == "a" ? "b" : "a"
            try await expect(!KeyCheck.isValid(String(body), prefix: String(key.prefix(4))))
        }
        try await expect(!KeyCheck.isValid("dkf_short", prefix: "dkf_"))
    }

    func wrongCounterInAdditionalDataFails() async throws {
        let p = f.phones[0]
        var a = p.slotAnswer
        a.counter += 1
        await expectThrows(SealError.notOpened) { try Sealing.open(a, pairing: p.pairing) }
    }

    func wrongSlotFails() async throws {
        let p = f.phones[0]
        var pairing = p.pairing
        pairing.slot = f.phones[1].slot
        await expectThrows(SealError.notOpened) { try Sealing.open(p.slotAnswer, pairing: pairing) }
    }

    func anotherPhonesKeyFails() async throws {
        let p = f.phones[0]
        var pairing = p.pairing
        pairing.key = f.phones[1].pairing.key
        await expectThrows(SealError.notOpened) { try Sealing.open(p.slotAnswer, pairing: pairing) }
    }

    func anyChangedByteFails() async throws {
        let p = f.phones[0]
        func flipped(_ s: String, at i: Int) -> String {
            var d = Data(base64Encoded: s)!
            d[i] ^= 1
            return d.base64EncodedString()
        }
        let a = p.slotAnswer
        let sizes = [a.slotNonce, a.key, a.nonce, a.body].map { Data(base64Encoded: $0)!.count }
        for field in 0..<4 {
            for i in Set([0, sizes[field] / 2, sizes[field] - 1]) {
                var b = a
                switch field {
                case 0: b.slotNonce = flipped(a.slotNonce, at: i)
                case 1: b.key = flipped(a.key, at: i)
                case 2: b.nonce = flipped(a.nonce, at: i)
                default: b.body = flipped(a.body, at: i)
                }
                await expectThrows(SealError.notOpened, "field \(field) byte \(i)") { try Sealing.open(b, pairing: p.pairing) }
            }
        }
    }

    func counterRule() async throws {
        let p = f.phones[0]
        await expectThrows(SealError.older) { try Sealing.open(p.slotAnswer, pairing: p.pairing, newest: f.counter + 1) }
        try await expect(try Sealing.open(p.slotAnswer, pairing: p.pairing, newest: f.counter).count > 0)
        try await expect(try Sealing.open(p.slotAnswer, pairing: p.pairing, newest: f.counter - 1).count > 0)
        try await expect(try Sealing.open(p.slotAnswer, pairing: p.pairing, newest: nil).count > 0)
    }

    func gzipRejectsGarbage() async throws {
        try await expect(Gzip.inflate(Data(repeating: 7, count: 40)) == nil)
        try await expect(Gzip.inflate(Data()) == nil)
    }
}
