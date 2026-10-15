import Foundation
@testable import DokkitKit

final class Stub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var seen: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Stub.seen.append(request)
        let (code, headers, body) = Stub.handler!(request)
        let r = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
        if let to = headers["Location"].flatMap(URL.init(string:)) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: to), redirectResponse: r)
        }
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    static func client(_ h: @escaping @Sendable (URLRequest) -> (Int, [String: String], Data)) -> RelayClient {
        handler = h
        seen = []
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [Stub.self]
        return RelayClient(session: URLSession(configuration: c))
    }
}

struct RelayTests {
    let phone = Fixtures.sealing.phones[0]

    func fetchesAndSendsBearerAndEtag() async throws {
        let body = try JSONEncoder().encode(phone.slotAnswer)
        let c = Stub.client { _ in (200, ["ETag": "\"184223\""], body) }
        let r = try await c.fetch(phone.pairing, etag: "\"1\"")
        try await expect(r == .fresh(phone.slotAnswer, etag: "\"184223\""))
        let req = try require(Stub.seen.first)
        try await expect(req.url?.absoluteString == "https://relay.example.com/m/\(phone.pairing.mailbox)/\(phone.slot)")
        try await expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer \(phone.token)")
        try await expect(req.value(forHTTPHeaderField: "If-None-Match") == "\"1\"")
    }

    func notModified() async throws {
        let c = Stub.client { _ in (304, [:], Data()) }
        try await expect(try await c.fetch(phone.pairing, etag: "x") == .notModified)
    }

    func notFound() async throws {
        let c = Stub.client { _ in (404, [:], Data()) }
        await expectThrows(RelayError.notFound) { try await c.fetch(phone.pairing, etag: nil) }
    }

    func rateLimited() async throws {
        let c = Stub.client { _ in (429, ["Retry-After": "17"], Data()) }
        await expectThrows(RelayError.rateLimited(retryAfter: 17)) { try await c.fetch(phone.pairing, etag: nil) }
    }

    func otherStatusAndBadBody() async throws {
        var c = Stub.client { _ in (503, [:], Data()) }
        await expectThrows(RelayError.status(503)) { try await c.fetch(phone.pairing, etag: nil) }
        c = Stub.client { _ in (200, [:], Data("nope".utf8)) }
        await expectThrows(RelayError.badAnswer) { try await c.fetch(phone.pairing, etag: nil) }
    }

    func refusesRedirect() async throws {
        let c = Stub.client { r in
            r.url?.host == "relay.example.com" ? (302, ["Location": "https://elsewhere.example.com/x"], Data()) : (200, [:], Data())
        }
        let followed: Bool
        do { _ = try await c.fetch(phone.pairing, etag: nil); followed = true } catch { followed = false }
        try await expect(!followed)
        try await expect(Stub.seen.count == 1, "the token went to \(Stub.seen.last?.url?.host ?? "")")
    }

    func refusesPlainHTTP() async throws {
        let c = Stub.client { _ in (200, [:], Data()) }
        var p = phone.pairing
        p.relay = "http://relay.example.com"
        await expectThrows(RelayError.notHTTPS) { try await c.fetch(p, etag: nil) }
        try await expect(Stub.seen.isEmpty)
    }

    func refresherOpensKeepsAndRefusesReplay() async throws {
        let body = try JSONEncoder().encode(phone.slotAnswer)
        let store = ServerStore(secrets: MemorySecrets(), files: MemoryFiles())
        let id = try await store.add(phone.pairing).id
        let r = Refresher(store: store, client: Stub.client { _ in (200, ["ETag": "\"184223\""], body) })

        let first = await r.refresh(id, now: Fixtures.now)
        try await expect(first.snapshot?.server?.name == "Northwind")
        try await expect(first.problem == nil && first.counter == 184223)

        let unchanged = Stub.client { _ in (304, [:], Data()) }
        let second = await Refresher(store: store, client: unchanged).refresh(id)
        try await expect(second.snapshot == first.snapshot)
        try await expect(Stub.seen.first?.value(forHTTPHeaderField: "If-None-Match") == "\"184223\"")

        let down = Stub.client { _ in (503, [:], Data()) }
        let third = await Refresher(store: store, client: down).refresh(id)
        try await expect(third.snapshot == first.snapshot)
        try await expect(third.problem?.contains("503") == true)

        var saved = try require(try await store.saved(id))
        saved.counter = 999_999
        saved.etag = nil
        try await store.save(id, saved)
        let replay = await Refresher(store: store, client: Stub.client { _ in (200, ["ETag": "\"184223\""], body) }).refresh(id)
        try await expect(replay.problem == SealError.older.errorDescription)
        try await expect(replay.snapshot == first.snapshot)
    }

    func refresherTreatsBrokenBodyAsNoSnapshot() async throws {
        var bad = phone.slotAnswer
        bad.body = Data(repeating: 1, count: 40).base64EncodedString()
        let body = try JSONEncoder().encode(bad)
        let store = ServerStore(secrets: MemorySecrets(), files: MemoryFiles())
        let id = try await store.add(phone.pairing).id
        let s = await Refresher(store: store, client: Stub.client { _ in (200, [:], body) }).refresh(id)
        try await expect(s.snapshot == nil)
        try await expect(s.problem == SealError.notOpened.errorDescription)
        try await expect(try await store.saved(id) == nil)
    }
}

struct StoreTests {
    let phones = Fixtures.sealing.phones

    func addReplaceRemove() async throws {
        let secrets = MemorySecrets(), files = MemoryFiles()
        let store = ServerStore(secrets: secrets, files: files)
        let s = try await store.add(phones[0].pairing)
        try await expect(s.id == Fixtures.sealing.mailbox)
        try await expect(try await store.servers().count == 1)
        try await expect(try await store.pairing(for: s.id) == phones[0].pairing)
        try await expect(secrets.accounts == ["\(s.id).key", "\(s.id).token"])
        try await expect(try files.read("servers.json").map { !String(decoding: $0, as: UTF8.self).contains(phones[0].token) } == true)

        let saved = SavedSnapshot(counter: 5, etag: nil, madeAt: nil, fetchedAt: Fixtures.now, json: Data("{}".utf8))
        try await store.save(s.id, saved)
        try await store.add(phones[1].pairing)
        try await expect(try await store.servers().count == 1)
        try await expect(try await store.pairing(for: s.id) == phones[1].pairing)
        try await expect(try await store.saved(s.id) == saved)

        try await store.remove(s.id)
        try await expect(try await store.servers().isEmpty)
        try await expect(try await store.saved(s.id) == nil)
        try await expect(try await store.pairing(for: s.id) == nil)
        try await expect(secrets.accounts.isEmpty)
        try await expect(files.names == ["servers.json"])
    }

    func diskFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dokkit-test-\(UUID().uuidString)")
        let f = DiskFiles(directory: dir)
        try await expect(try f.read("a") == nil)
        try f.write("a", Data("x".utf8))
        try await expect(try f.read("a") == Data("x".utf8))
        let v = try dir.appendingPathComponent("a").resourceValues(forKeys: [.isExcludedFromBackupKey])
        try await expect(v.isExcludedFromBackup == true)
        try f.remove("a")
        try f.remove("a")
        try await expect(try f.read("a") == nil)
    }
}
