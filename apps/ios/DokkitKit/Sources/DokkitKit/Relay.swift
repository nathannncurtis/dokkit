import Foundation

public enum RelayError: Error, Equatable, LocalizedError {
    case notHTTPS, notFound, rateLimited(retryAfter: Int?), status(Int), badAnswer, network(String)

    public var errorDescription: String? {
        switch self {
        case .notHTTPS: "The relay address is not https, so the app did not contact it."
        case .notFound: "The relay does not know this phone. It may have been removed in Dokkit; pair it again."
        case .rateLimited(let s): "The relay says this phone is asking too often" + (s.map { "; try again in \($0) seconds." } ?? ".")
        case .status(let n): "The relay answered with an error (\(n))."
        case .badAnswer: "The relay sent an answer the app could not read."
        case .network(let m): "The relay could not be reached (\(m))."
        }
    }
}

public enum FetchResult: Sendable, Equatable {
    case fresh(SlotAnswer, etag: String?)
    case notModified
}

public struct RelayClient: Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let c = URLSessionConfiguration.ephemeral
            c.urlCache = nil
            c.requestCachePolicy = .reloadIgnoringLocalCacheData
            c.timeoutIntervalForRequest = 20
            c.httpCookieStorage = nil
            self.session = URLSession(configuration: c)
        }
    }

    public func fetch(_ p: Pairing, etag: String?) async throws -> FetchResult {
        var base = p.relay
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/m/\(p.mailbox)/\(p.slot)"), url.scheme?.lowercased() == "https" else {
            throw RelayError.notHTTPS
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(p.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) } catch { throw RelayError.network(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw RelayError.badAnswer }
        switch http.statusCode {
        case 200:
            guard let a = try? JSONDecoder().decode(SlotAnswer.self, from: data) else { throw RelayError.badAnswer }
            return .fresh(a, etag: http.value(forHTTPHeaderField: "ETag"))
        case 304: return .notModified
        case 404: throw RelayError.notFound
        case 429: throw RelayError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) })
        case let n: throw RelayError.status(n)
        }
    }
}
