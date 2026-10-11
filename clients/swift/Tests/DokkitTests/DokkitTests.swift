import Foundation
import XCTest
@testable import Dokkit

final class Fake: URLProtocol {
    struct Seen { let path: String, body: String }
    static let lock = NSLock()
    static var seen: [Seen] = []
    static var statuses: [String: [Int]] = [:]

    static func reset(_ statuses: [String: [Int]] = [:]) {
        lock.lock(); defer { lock.unlock() }
        seen = []
        self.statuses = statuses
    }

    static func paths(_ path: String) -> [Seen] {
        lock.lock(); defer { lock.unlock() }
        return seen.filter { $0.path == path }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "127.0.0.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var data = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
        } else if let body = request.httpBody {
            data = body
        }
        let path = request.url?.path ?? ""
        Fake.lock.lock()
        Fake.seen.append(Seen(path: path, body: String(decoding: data, as: UTF8.self)))
        var status = 200
        if var queued = Fake.statuses[path], !queued.isEmpty {
            status = queued.removeFirst()
            Fake.statuses[path] = queued
        }
        Fake.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class DokkitTests: XCTestCase {
    override func setUp() {
        URLProtocol.registerClass(Fake.self)
        Dokkit.reset()
        Fake.reset()
    }

    override func tearDown() {
        Dokkit.reset()
        URLProtocol.unregisterClass(Fake.self)
    }

    private func start(version: String? = nil, environment: String? = nil, announceVersion: Bool = true) {
        Dokkit.start(version: version, environment: environment, url: "http://127.0.0.1:9", key: "dka_test", host: "test", announceVersion: announceVersion)
        let until = Date().addingTimeInterval(5)
        while !Dokkit.started && Date() < until { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(Dokkit.started)
    }

    private var reports: String { Fake.paths("/api/v1/report").map { $0.body }.joined(separator: "\n") }

    private struct Boom: Error {}

    func testDeployLineIsSentOnce() {
        start(version: "2.3.0")
        Dokkit.flush()
        Dokkit.flush()
        XCTAssertEqual(reports.components(separatedBy: "\"type\":\"deploy\"").count - 1, 1)
        XCTAssertTrue(reports.contains("\"version\":\"2.3.0\""))
    }

    func testAnnounceVersionFalseSendsNoDeployLine() {
        start(version: "2.3.0", announceVersion: false)
        Dokkit.log("info", "hello")
        Dokkit.flush()
        XCTAssertTrue(reports.contains("hello"))
        XCTAssertFalse(reports.contains("deploy"))
    }

    func testErrorPostIsKeptWhenTheServerFailsAndLogsStillGo() {
        Fake.reset(["/api/v1/errors": [503]])
        start()
        Dokkit.capture(Boom())
        Dokkit.log("info", "still sent")
        Dokkit.flush()
        XCTAssertEqual(Fake.paths("/api/v1/errors").count, 1)
        XCTAssertTrue(reports.contains("still sent"))
        Dokkit.flush()
        XCTAssertEqual(Fake.paths("/api/v1/errors").count, 2)
        Dokkit.flush()
        XCTAssertEqual(Fake.paths("/api/v1/errors").count, 2)
        XCTAssertEqual(Dokkit.dropped, 0)
    }

    func testErrorPostRefusedWith4xxIsDroppedAndCounted() {
        Fake.reset(["/api/v1/errors": [400]])
        start()
        Dokkit.capture(Boom())
        Dokkit.flush()
        Dokkit.flush()
        XCTAssertEqual(Fake.paths("/api/v1/errors").count, 1)
        XCTAssertEqual(Dokkit.dropped, 1)
    }

    func testFailedLogBatchDoesNotStopErrorPosts() {
        Fake.reset(["/api/v1/report": [500]])
        start()
        Dokkit.log("info", "lost once")
        Dokkit.capture(Boom())
        Dokkit.flush()
        XCTAssertEqual(Fake.paths("/api/v1/errors").count, 1)
    }

    func testLongMessageIsCutToTheLimitInBytes() {
        start()
        Dokkit.log("info", String(repeating: "é", count: 100_000))
        Dokkit.flush()
        let line = reports.split(separator: "\n").first { $0.contains("\"type\":\"log\"") }
        XCTAssertNotNil(line)
        XCTAssertLessThanOrEqual(line!.utf8.count, 65536)
        XCTAssertTrue(line!.contains(" [cut]\""))
        XCTAssertEqual(Dokkit.dropped, 0)
    }

    func testDevelopmentEnvironmentIsOnEveryLine() {
        start(version: "1.0.0", environment: "dev")
        Dokkit.log("info", "a log")
        Dokkit.beat("sync")
        Dokkit.job("nightly") { _ in }
        Dokkit.flush()
        let lines = reports.split(separator: "\n")
        XCTAssertGreaterThanOrEqual(lines.count, 5)
        for line in lines { XCTAssertTrue(line.contains("\"environment\":\"dev\""), String(line)) }
    }

    func testProductionEnvironmentAddsNothing() {
        start(version: "1.0.0", environment: "production")
        Dokkit.log("info", "a log")
        Dokkit.beat("sync")
        Dokkit.flush()
        XCTAssertFalse(reports.contains("environment"))
    }

    func testShortMessageIsNotCut() {
        start()
        Dokkit.log("info", "short")
        Dokkit.flush()
        XCTAssertFalse(reports.contains("[cut]"))
    }
}
