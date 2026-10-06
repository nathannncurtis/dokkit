// The Dokkit client library for Swift. One file, Foundation only. iOS 13, macOS 10.15 or later.
//
//     Dokkit.start(version: "2.3.0", url: "https://dokkit.example", key: "dka_...")
//     Dokkit.beat("sync")                       // from a timer
//     try Dokkit.job("nightly-purge") { run in run.progress(4000, of: 9000) }
//     Dokkit.check("queue-age", "degraded", value: 14, note: "oldest item is 14 minutes old")
//     Dokkit.capture(error)
//
// With no address or key, `start` reads DOKKIT_URL and DOKKIT_KEY; blank means off. Nothing
// here throws into the app or waits on the network. Lines wait in a queue of fixed size and
// a timer sends them. Error message text is never sent.

import Foundation

public enum Dokkit {
    private static let queue = DispatchQueue(label: "dokkit")
    private static var on: (url: String, key: String, version: String?, environment: String?, host: String)?
    private static var lines: [[String: Any]] = []
    private static var errors: [[String: Any]] = []
    private static var timer: DispatchSourceTimer?
    private static var droppedCount = 0

    /// How many lines were dropped because the queue was full.
    public static var dropped: Int { queue.sync { droppedCount } }

    /// Turns the library on. With no address or key it stays off and every call does nothing.
    public static func start(version: String? = nil, environment: String? = nil, url: String? = nil, key: String? = nil) {
        let env = ProcessInfo.processInfo.environment
        guard let url = url ?? env["DOKKIT_URL"], let key = key ?? env["DOKKIT_KEY"], !url.isEmpty, !key.isEmpty else { return }
        queue.sync {
            guard on == nil else { return }
            var address = url
            while address.hasSuffix("/") { address.removeLast() }
            on = (address, key, version, environment ?? env["DOKKIT_ENV"], ProcessInfo.processInfo.hostName)
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 2, repeating: 2)
            t.setEventHandler { send() }
            t.resume()
            timer = t
        }
        if let version = version { add(["type": "deploy", "version": version]) }
    }

    public static func beat(_ name: String, everySeconds: Int = 60) {
        add(["type": "beat", "name": name, "every_seconds": everySeconds])
    }

    /// `state` is "ok", "degraded" or "down".
    public static func check(_ name: String, _ state: String, value: Double? = nil, note: String? = nil) {
        add(["type": "custom", "check": name, "state": state, "value": value, "note": note])
    }

    public static func metric(_ name: String, _ value: Double, unit: String? = nil) {
        add(["type": "metric", "name": name, "value": value, "unit": unit])
    }

    /// `level` is trace, debug, info, warn, error or fatal.
    public static func log(_ level: String, _ message: String) {
        add(["type": "log", "t": now(), "level": level, "msg": message])
    }

    /// Sends a stats document, for an app dokkit cannot reach.
    public static func stats(_ document: [String: Any]) {
        add(["type": "stats", "document": document])
    }

    /// One run of a job.
    public struct Run {
        let name: String
        let id = UUID().uuidString.lowercased()

        func send(_ event: String, _ more: [String: Any?] = [:]) {
            Dokkit.add(["type": "job", "name": name, "run": id, "event": event].merging(more) { $1 })
        }

        public func progress(_ done: Int, of total: Int? = nil) { send("progress", ["done": done, "total": total]) }
    }

    /// Reports a run of a job: its start, its progress, and how it ended. Returns what the work returns.
    @discardableResult
    public static func job<T>(_ name: String, _ work: (Run) throws -> T) rethrows -> T {
        let run = Run(name: name)
        let began = Date()
        let took = { Int(Date().timeIntervalSince(began) * 1000) }
        run.send("start")
        do {
            let result = try work(run)
            run.send("ok", ["exit_code": 0, "duration_ms": took()])
            return result
        } catch {
            run.send("fail", ["exit_code": 1, "duration_ms": took()])
            capture(error, handled: false)
            throw error
        }
    }

    /// Sends an error: its type and the stack of the place that reported it, never its message.
    public static func capture(_ error: Error, handled: Bool = true, tags: [String: String] = [:]) {
        // Swift keeps no stack with an error. Each symbol line reads "3  MyApp  0x0001  function + 12".
        let stack = Thread.callStackSymbols.dropFirst().compactMap { text -> [String: Any]? in
            let parts = text.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4 else { return nil }
            let function = parts[3].components(separatedBy: " + ").first ?? String(parts[3])
            return ["file": String(parts[1]), "function": function, "own": String(parts[1]) == ProcessInfo.processInfo.processName]
        }
        queue.async {
            guard let on = on, errors.count < 100 else { return }
            errors.append(clean([
                "at": now(), "type": String(describing: type(of: error)), "handled": handled, "release": on.version,
                "environment": on.environment, "host": on.host,
                // Innermost last, as the format asks.
                "frames": Array(stack.reversed()), "tags": tags,
            ]))
        }
    }

    /// Sends what is waiting and returns when it has gone. Call it before the app is suspended.
    public static func flush() {
        queue.sync { send(wait: true) }
    }

    private static func add(_ line: [String: Any?]) {
        queue.async {
            guard let on = on else { return }
            if lines.count >= 1000 {
                lines.removeFirst()
                droppedCount += 1
            }
            var line = clean(line)
            line["at"] = now()
            line["host"] = on.host
            lines.append(line)
        }
    }

    // Nil values are left out of a line.
    private static func clean(_ line: [String: Any?]) -> [String: Any] {
        line.compactMapValues { $0 }
    }

    private static func now() -> String { ISO8601DateFormatter().string(from: Date()) }

    // Runs on the queue. What cannot be sent is dropped. The app is never told.
    private static func send(wait: Bool = false) {
        guard let on = on else { return }
        let done = DispatchGroup()
        func post(_ path: String, _ body: Data, _ kind: String) {
            guard let url = URL(string: on.url + path) else { return }
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("Bearer " + on.key, forHTTPHeaderField: "Authorization")
            request.setValue(kind, forHTTPHeaderField: "Content-Type")
            request.setValue(UUID().uuidString, forHTTPHeaderField: "Dokkit-Batch")
            done.enter()
            URLSession.shared.dataTask(with: request) { _, _, _ in done.leave() }.resume()
        }
        for error in errors {
            if let body = try? JSONSerialization.data(withJSONObject: error) { post("/api/v1/errors", body, "application/json") }
        }
        errors = []
        while !lines.isEmpty {
            let batch = lines.prefix(500).compactMap { line in
                (try? JSONSerialization.data(withJSONObject: line)).flatMap { String(data: $0, encoding: .utf8) }
            }
            lines.removeFirst(min(500, lines.count))
            post("/api/v1/report", Data(batch.joined(separator: "\n").utf8), "application/x-ndjson")
        }
        if wait { _ = done.wait(timeout: .now() + 10) }
    }
}
