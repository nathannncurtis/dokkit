import Foundation

public struct ServerState: Sendable, Equatable {
    public var snapshot: Snapshot?
    public var madeAt: Date?
    public var counter: Int?
    public var problem: String?

    public init(snapshot: Snapshot? = nil, madeAt: Date? = nil, counter: Int? = nil, problem: String? = nil) {
        (self.snapshot, self.madeAt, self.counter, self.problem) = (snapshot, madeAt, counter, problem)
    }
}

public struct Refresher: Sendable {
    public let store: ServerStore
    public let client: RelayClient

    public init(store: ServerStore, client: RelayClient = RelayClient()) {
        (self.store, self.client) = (store, client)
    }

    public func load(_ id: String) async -> ServerState {
        guard let s = try? await store.saved(id) else { return ServerState() }
        return Self.state(s, problem: nil)
    }

    public func refresh(_ id: String, now: Date = Date()) async -> ServerState {
        let saved = try? await store.saved(id)
        var problem: String?
        do {
            guard let p = try await store.pairing(for: id) else { return Self.state(saved, problem: "This server is no longer paired.") }
            switch try await client.fetch(p, etag: saved?.etag) {
            case .notModified:
                break
            case .fresh(let answer, let etag):
                let json = try Sealing.open(answer, pairing: p, newest: saved?.counter)
                let snap = try Snapshot.decode(json)
                let next = SavedSnapshot(
                    counter: answer.counter, etag: etag,
                    madeAt: answer.madeAt.flatMap(Snapshot.parseDate) ?? snap.server?.madeAt,
                    fetchedAt: now, json: json)
                try await store.save(id, next)
                return Self.state(next, problem: nil)
            }
        } catch is DecodingError {
            problem = "The snapshot was opened but could not be read. This app may be older than the server."
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        return Self.state(saved, problem: problem)
    }

    private static func state(_ s: SavedSnapshot?, problem: String?) -> ServerState {
        guard let s, let snap = try? Snapshot.decode(s.json) else { return ServerState(problem: problem) }
        return ServerState(snapshot: snap, madeAt: s.madeAt, counter: s.counter, problem: problem)
    }
}
