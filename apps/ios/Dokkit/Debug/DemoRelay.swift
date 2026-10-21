#if DEBUG
import Compression
import CryptoKit
import Foundation

// Debug builds only: a made-up relay at demo.dokkit.invalid that seals the demo snapshot the way a server does, so
// the app can be looked at in the simulator without a Dokkit server. Paste NORTHWIND_CODE ("northwind" has things that
// need you) or HARBOR_LAB_CODE ("harbor-lab" has everything fine) into Add a server.
final class DemoRelay: URLProtocol {
    static let NORTHWIND_CODE = "dokkit-phone:1:eyJyZWxheSI6Imh0dHBzOi8vZGVtby5kb2traXQuaW52YWxpZCIsIm1haWxib3giOiJjOWZkOWJkMGFlN2UyZjBlMWQzOTZmMWUxMzNkNGVkOCIsInNsb3QiOiIwMWVjNmFiNDAxZGU4OWFjOWQ5ZWUzZWQzNmQ3YzdlNiIsInRva2VuIjoiZGtmX3NKZ2pmVFVER3ZsNUREZGpLRjBXM09xMGV1b3I1STF1YlNPNiIsImtleSI6IjVpREZ3U1VGUDNrQTBHS2pXQ3JBZnRvOVZ3Z3draU43NkJQS08vejMyZVE9IiwibmFtZSI6Im5vcnRod2luZCJ9"
    static let HARBOR_LAB_CODE = "dokkit-phone:1:eyJyZWxheSI6Imh0dHBzOi8vZGVtby5kb2traXQuaW52YWxpZCIsIm1haWxib3giOiIzOWU2ZjUwY2M3MjE4Yjc0ZmM3ZTY1ODkxZDM2OGM3MSIsInNsb3QiOiI3NDIzODE2YzZjNzA1ZWRhYmIwMWY2NDMzMGVhODIzZCIsInRva2VuIjoiZGtmX0VTWUx5cVlYYXNFU1F4Mk54aWJOZG9tMUlGVm9odDNSNDNrQSIsImtleSI6Inc5ZnQ2Q3RZaG01Tnp1Z0xlNXFEeDNwNDdPNk5ZcW0rVXRHM2FJL1l6MTQ9IiwibmFtZSI6ImhhcmJvci1sYWIifQ=="

    private struct Demo {
        let mailbox: String
        let slot: String
        let key: String
        let asset: String
    }

    private static let demos = [
        Demo(mailbox: "c9fd9bd0ae7e2f0e1d396f1e133d4ed8", slot: "01ec6ab401de89ac9d9ee3ed36d7c7e6", key: "5iDFwSUFP3kA0GKjWCrAfto9VwgwkiN76BPKO/z32eQ=", asset: "demo-snapshot"),
        Demo(mailbox: "39e6f50cc7218b74fc7e65891d368c71", slot: "7423816c6c705edabb01f64330ea823d", key: "w9ft6CtYhm5NzugLe5qDx3p47O6NYqm+UtG3aI/Yz14=", asset: "demo-fine"),
    ]

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "demo.dokkit.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        guard let demo = Self.demos.first(where: { url.path.contains("/m/\($0.mailbox)/") }),
              let body = try? Self.answer(demo) else {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func answer(_ demo: Demo) throws -> Data {
        let now = Date()
        let raw = try Data(contentsOf: Bundle.main.url(forResource: demo.asset, withExtension: "json")!)
        var doc = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let generated = (doc["generated_at"] as? String).flatMap { iso.date(from: $0) ?? plain.date(from: $0) } ?? now
        let shift = now.timeIntervalSince(generated)
        func moved(_ v: Any) -> Any {
            if let d = v as? [String: Any] { return d.mapValues(moved) }
            if let a = v as? [Any] { return a.map(moved) }
            if let s = v as? String, s.count >= 20, s.dropFirst(4).first == "-", let t = iso.date(from: s) ?? plain.date(from: s) {
                return iso.string(from: t.addingTimeInterval(shift))
            }
            return v
        }
        doc = doc.mapValues(moved)
        let counter = Int(now.timeIntervalSince1970)
        var server = doc["server"] as? [String: Any] ?? [:]
        server["made_at"] = iso.string(from: now.addingTimeInterval(-40))
        server["counter"] = counter
        doc["server"] = server
        let json = try JSONSerialization.data(withJSONObject: doc)

        let contentKey = SymmetricKey(size: .bits256)
        let slotNonce = AES.GCM.Nonce()
        let bodyNonce = AES.GCM.Nonce()
        let phoneKey = SymmetricKey(data: Data(base64Encoded: demo.key)!)
        let keyBytes = contentKey.withUnsafeBytes { Data($0) }
        let wrapped = try AES.GCM.seal(keyBytes, using: phoneKey, nonce: slotNonce, authenticating: Data("dokkit-phone-v1|\(demo.mailbox)|\(demo.slot)|\(counter)".utf8))
        let sealed = try AES.GCM.seal(gzip(json), using: contentKey, nonce: bodyNonce, authenticating: Data("dokkit-phone-v1|\(demo.mailbox)|body|\(counter)".utf8))
        let answer: [String: Any] = [
            "schema": 1, "counter": counter, "made_at": iso.string(from: now.addingTimeInterval(-40)),
            "slot_nonce": Data(slotNonce).base64EncodedString(), "key": (wrapped.ciphertext + wrapped.tag).base64EncodedString(),
            "nonce": Data(bodyNonce).base64EncodedString(), "body": (sealed.ciphertext + sealed.tag).base64EncodedString(),
        ]
        return try JSONSerialization.data(withJSONObject: answer)
    }

    // A gzip stream: Apple's raw deflate between the gzip header and its CRC-32 and length.
    private static func gzip(_ d: Data) -> Data {
        let src = [UInt8](d)
        var out = [UInt8](repeating: 0, count: src.count + 1024)
        let n = compression_encode_buffer(&out, out.count, src, src.count, nil, COMPRESSION_ZLIB)
        var crc: UInt32 = 0xffff_ffff
        for b in src {
            crc ^= UInt32(b)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xedb8_8320 & (0 &- (crc & 1))) }
        }
        crc = ~crc
        let size = UInt32(truncatingIfNeeded: src.count)
        var g: [UInt8] = [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255]
        g += out[0..<n]
        g += [UInt8(crc & 255), UInt8(crc >> 8 & 255), UInt8(crc >> 16 & 255), UInt8(crc >> 24)]
        g += [UInt8(size & 255), UInt8(size >> 8 & 255), UInt8(size >> 16 & 255), UInt8(size >> 24)]
        return Data(g)
    }
}
#endif
