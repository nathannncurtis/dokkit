import Foundation
import Observation
import DokkitKit

@MainActor @Observable
public final class AppModel {
    public private(set) var servers: [PairedServer] = []
    public private(set) var states: [String: ServerState] = [:]
    public private(set) var refreshing = false
    public var selectedID: String?
    public private(set) var loaded = false
    var openMachines: [String: Bool] = [:]
    var openMore: [String: Bool] = [:]
    var pasteOnly = false
    var addingServer = false
    var removing: PairedServer?
    var addError: String?
    var pasted = ""
    var addWorking = false
    var tab = 0
    var picking = false
    var homePath: [Page] = []
    var serversPath: [Page] = []
    var firstPath: [Page] = []
    public var settings: AppSettings = AppSettings.decode(UserDefaults.standard.data(forKey: AppModel.settingsKey)) {
        didSet { UserDefaults.standard.set(settings.encoded(), forKey: AppModel.settingsKey) }
    }
    private let refresher: Refresher

    public nonisolated static let settingsKey = "settings"

    /// The relay timeout as saved, readable from any thread for the relay client.
    public nonisolated static let relayTimeout: @Sendable () -> TimeInterval = {
        TimeInterval(AppSettings.decode(UserDefaults.standard.data(forKey: AppModel.settingsKey)).relayWaitSeconds)
    }

    public init(refresher: Refresher) { self.refresher = refresher }

    func freshness(_ st: ServerState, now: Date) -> Freshness {
        Freshness.make(madeAt: st.madeAt, hasSnapshot: st.snapshot != nil, problem: st.problem, now: now, late: TimeInterval(settings.lateMinutes * 60))
    }

    func open(_ page: Page) {
        if tab == 1 { serversPath.append(page) } else { homePath.append(page) }
    }

    public var selected: PairedServer? { servers.first { $0.id == selectedID } ?? servers.first }
    public var selectedState: ServerState { selected.flatMap { states[$0.id] } ?? ServerState() }

    public func load() async {
        servers = (try? await refresher.store.servers()) ?? []
        for s in servers where states[s.id] == nil { states[s.id] = await refresher.load(s.id) }
        loaded = true
    }

    public func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let ids = servers.map(\.id)
        let r = refresher
        let results = await withTaskGroup(of: (String, ServerState).self) { group in
            for id in ids { group.addTask { (id, await r.refresh(id)) } }
            var out: [String: ServerState] = [:]
            for await (id, st) in group { out[id] = st }
            return out
        }
        for (id, st) in results where servers.contains(where: { $0.id == id }) { states[id] = st }
    }

    public func add(code: String) async -> String? {
        do {
            let p = try Pairing.parse(code)
            let s = try await refresher.store.add(p)
            selectedID = s.id
            await load()
            states[s.id] = await refresher.refresh(s.id)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    public func remove(_ id: String) async {
        try? await refresher.store.remove(id)
        states[id] = nil
        if selectedID == id { selectedID = nil }
        await load()
    }
}

enum Page: Hashable {
    case service(String, from: String?)
    case machine(String)
    case add(paste: Bool)
}
