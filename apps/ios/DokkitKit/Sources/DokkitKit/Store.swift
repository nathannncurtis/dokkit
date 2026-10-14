import Foundation
#if canImport(Security)
import Security
#endif

public protocol SecretStore: Sendable {
    func get(_ account: String) throws -> Data?
    func set(_ account: String, _ data: Data) throws
    func remove(_ account: String) throws
}

public protocol FileStore: Sendable {
    func read(_ name: String) throws -> Data?
    func write(_ name: String, _ data: Data) throws
    func remove(_ name: String) throws
}

public final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    public init() {}
    public func get(_ a: String) throws -> Data? { lock.withLock { items[a] } }
    public func set(_ a: String, _ d: Data) throws { lock.withLock { items[a] = d } }
    public func remove(_ a: String) throws { _ = lock.withLock { items.removeValue(forKey: a) } }
    public var accounts: [String] { lock.withLock { items.keys.sorted() } }
}

public final class MemoryFiles: FileStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    public init() {}
    public func read(_ n: String) throws -> Data? { lock.withLock { items[n] } }
    public func write(_ n: String, _ d: Data) throws { lock.withLock { items[n] = d } }
    public func remove(_ n: String) throws { _ = lock.withLock { items.removeValue(forKey: n) } }
    public var names: [String] { lock.withLock { items.keys.sorted() } }
}

public struct StoreError: Error, LocalizedError {
    public let errorDescription: String?
}

public struct KeychainSecrets: SecretStore {
    private let service: String
    public init(service: String = "dev.dokkit.phone") { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    public func get(_ account: String) throws -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s == errSecItemNotFound { return nil }
        guard s == errSecSuccess else { throw StoreError(errorDescription: "The Keychain could not be read (\(s)).") }
        return out as? Data
    }

    public func set(_ account: String, _ data: Data) throws {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let s = SecItemAdd(q as CFDictionary, nil)
        guard s == errSecSuccess else { throw StoreError(errorDescription: "The Keychain could not be written (\(s)).") }
    }

    public func remove(_ account: String) throws {
        let s = SecItemDelete(query(account) as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw StoreError(errorDescription: "The Keychain could not be changed (\(s)).") }
    }
}

public struct DiskFiles: FileStore {
    private let dir: URL
    public init(directory: URL) { dir = directory }

    public func read(_ name: String) throws -> Data? {
        let url = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }

    public func write(_ name: String, _ data: Data) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir.appendingPathComponent(name)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: url, options: options)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    public func remove(_ name: String) throws {
        let url = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

public struct PairedServer: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var relay: String
    public var mailbox: String
    public var slot: String
    public var addedAt: Date
    public var id: String { mailbox }
}

public struct SavedSnapshot: Codable, Sendable, Equatable {
    public var counter: Int
    public var etag: String?
    public var madeAt: Date?
    public var fetchedAt: Date
    public var json: Data
}

public actor ServerStore {
    private let secrets: any SecretStore
    private let files: any FileStore
    private static let list = "servers.json"

    public init(secrets: any SecretStore, files: any FileStore) {
        self.secrets = secrets
        self.files = files
    }

    public func servers() throws -> [PairedServer] {
        guard let d = try files.read(Self.list) else { return [] }
        return try JSONDecoder().decode([PairedServer].self, from: d)
    }

    @discardableResult
    public func add(_ p: Pairing, now: Date = Date()) throws -> PairedServer {
        let server = PairedServer(name: p.name, relay: p.relay, mailbox: p.mailbox, slot: p.slot, addedAt: now)
        try secrets.set("\(p.mailbox).key", Data(p.key.utf8))
        try secrets.set("\(p.mailbox).token", Data(p.token.utf8))
        var all = try servers().filter { $0.id != server.id }
        all.append(server)
        try files.write(Self.list, JSONEncoder().encode(all))
        return server
    }

    public func pairing(for id: String) throws -> Pairing? {
        guard let s = try servers().first(where: { $0.id == id }),
              let k = try secrets.get("\(id).key"), let t = try secrets.get("\(id).token"),
              let key = String(data: k, encoding: .utf8), let token = String(data: t, encoding: .utf8)
        else { return nil }
        return Pairing(relay: s.relay, mailbox: s.mailbox, slot: s.slot, token: token, key: key, name: s.name)
    }

    public func remove(_ id: String) throws {
        try secrets.remove("\(id).key")
        try secrets.remove("\(id).token")
        try files.remove(Self.snapshotFile(id))
        try files.write(Self.list, JSONEncoder().encode(servers().filter { $0.id != id }))
    }

    public func saved(_ id: String) throws -> SavedSnapshot? {
        guard let d = try files.read(Self.snapshotFile(id)) else { return nil }
        return try? JSONDecoder().decode(SavedSnapshot.self, from: d)
    }

    public func save(_ id: String, _ s: SavedSnapshot) throws {
        try files.write(Self.snapshotFile(id), JSONEncoder().encode(s))
    }

    private static func snapshotFile(_ id: String) -> String { "snapshot-\(id).json" }
}
