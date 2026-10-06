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
// a timer sends them. Error message text is never sent. An http:// address to another machine
// keeps the library off unless DOKKIT_INSECURE=1.

import Foundation

public enum Dokkit {
    private static let queue = DispatchQueue(label: "dokkit")
    private static var on: (url: String, key: String, version: String?, environment: String?, host: String)?
    private static var lines: [String] = []
    private static var lineBytes = 0
    private static var errors: [[String: Any]] = []
    private static var retry: [Batch] = []
    private static let queueBytes = 4 << 20
    private static let stamp = ISO8601DateFormatter()

    private struct Batch {
        let path: String, body: Data, kind: String, count: Int
        let id = UUID().uuidString
        var tries = 0
    }
    private static var timer: DispatchSourceTimer?
    private static var droppedCount = 0

    /// How many lines were dropped because the queue was full or could not be sent.
    public static var dropped: Int { queue.sync { droppedCount } }

    /// Turns the library on. With no address or key it stays off and every call does nothing.
    /// `host` names this machine; without it the system's host name is used, and a generic name on phones and tablets.
    public static func start(version: String? = nil, environment: String? = nil, url: String? = nil, key: String? = nil, host: String? = nil) {
        let env = ProcessInfo.processInfo.environment
        guard let url = url ?? env["DOKKIT_URL"], let key = key ?? env["DOKKIT_KEY"], !url.isEmpty, !key.isEmpty else { return }
        if url.lowercased().hasPrefix("http://") && env["DOKKIT_INSECURE"] != "1" {
            let name = URL(string: url)?.host ?? ""
            if name != "localhost" && name != "::1" && !name.hasPrefix("127.") {
                FileHandle.standardError.write(Data("dokkit: \(url) is not https and not this machine; staying off. Set DOKKIT_INSECURE=1 to allow it.\n".utf8))
                return
            }
        }
        // The host name can take seconds to look up, so it is read on the queue, never on the caller's thread.
        queue.async {
            guard on == nil else { return }
            var address = url
            while address.hasSuffix("/") { address.removeLast() }
            #if os(macOS) || os(Linux)
            let name = host ?? ProcessInfo.processInfo.hostName
            #else
            let name = host ?? "device"
            #endif
            on = (address, key, version, environment ?? env["DOKKIT_ENV"], name)
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 2, repeating: 2)
            t.setEventHandler { send() }
            t.resume()
            timer = t
            if let version = version { add(["type": "deploy", "version": version]) }
        }
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
            var line = clean(line)
            line["at"] = now()
            line["host"] = on.host
            guard JSONSerialization.isValidJSONObject(line), let data = try? JSONSerialization.data(withJSONObject: line),
                  let text = String(data: data, encoding: .utf8) else { return }
            if text.utf8.count > queueBytes {
                droppedCount += 1
                return
            }
            while !lines.isEmpty && (lines.count >= 1000 || lineBytes + text.utf8.count > queueBytes) {
                lineBytes -= lines.removeFirst().utf8.count
                droppedCount += 1
            }
            lines.append(text)
            lineBytes += text.utf8.count
        }
    }

    // Nil values are left out of a line.
    private static func clean(_ line: [String: Any?]) -> [String: Any] {
        line.compactMapValues { $0 }
    }

    private static func now() -> String { stamp.string(from: Date()) }

    // Runs on the queue. A failed batch gets one more try; what is lost then is counted. The app is never told.
    private static func send(wait: Bool = false) {
        guard let on = on else { return }
        let done = DispatchGroup()
        func post(_ batch: Batch) {
            guard let url = URL(string: on.url + batch.path) else {
                droppedCount += batch.count
                return
            }
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.httpMethod = "POST"
            request.httpBody = batch.body
            request.setValue("Bearer " + on.key, forHTTPHeaderField: "Authorization")
            request.setValue(batch.kind, forHTTPHeaderField: "Content-Type")
            request.setValue(batch.id, forHTTPHeaderField: "Dokkit-Batch")
            done.enter()
            URLSession.shared.dataTask(with: request) { _, response, _ in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 599
                if status >= 400 {
                    queue.async {
                        var batch = batch
                        if (status >= 500 || status == 429) && batch.tries == 0 {
                            batch.tries = 1
                            retry.append(batch)
                        } else {
                            droppedCount += batch.count
                        }
                    }
                }
                done.leave()
            }.resume()
        }
        let again = retry
        retry = []
        again.forEach(post)
        // At most ten errors a tick; the rest wait for the next one.
        for error in errors.prefix(10) {
            if let body = try? JSONSerialization.data(withJSONObject: error) {
                post(Batch(path: "/api/v1/errors", body: body, kind: "application/json", count: 1))
            }
        }
        errors.removeFirst(min(10, errors.count))
        while !lines.isEmpty {
            let batch = Array(lines.prefix(500))
            lines.removeFirst(batch.count)
            lineBytes -= batch.reduce(0) { $0 + $1.utf8.count }
            post(Batch(path: "/api/v1/report", body: Data(batch.joined(separator: "\n").utf8), kind: "application/x-ndjson", count: batch.count))
        }
        if wait { _ = done.wait(timeout: .now() + 10) }
    }
}
