import Foundation

public enum ThemeChoice: String, Codable, CaseIterable, Sendable {
    case system = "System", light = "Light", dark = "Dark"
    public var word: String { rawValue }
}

public enum LockAfter: String, Codable, CaseIterable, Sendable {
    case everyReturn, afterMinute, afterFiveMinutes

    public var word: String {
        switch self {
        case .everyReturn: "Every launch and every return"
        case .afterMinute: "Every launch, and after 1 min away"
        case .afterFiveMinutes: "Every launch, and after 5 min away"
        }
    }

    public var seconds: TimeInterval {
        switch self {
        case .everyReturn: 0
        case .afterMinute: 60
        case .afterFiveMinutes: 300
        }
    }
}

/// What the app used to hard-code, with today's values as the defaults.
public struct AppSettings: Codable, Equatable, Sendable {
    public var theme: ThemeChoice = .system
    public var refreshSeconds: Int = 30
    public var lateMinutes: Int = Int(Age.warnAfter) / 60
    public var hotPercent: Int = Int(Home.hotAbove)
    public var fineShown: Int = Home.fineShown
    public var relayWaitSeconds: Int = 20
    public var lockAfter: LockAfter = .everyReturn

    public init() {}

    public enum Limits {
        public static let refresh = 10...600
        public static let late = 1...120
        public static let hot = 1...100
        public static let fineShown = 1...100
        public static let relayWait = 5...120
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        theme = (try? c.decode(ThemeChoice.self, forKey: .theme)) ?? d.theme
        refreshSeconds = (try? c.decode(Int.self, forKey: .refreshSeconds)) ?? d.refreshSeconds
        lateMinutes = (try? c.decode(Int.self, forKey: .lateMinutes)) ?? d.lateMinutes
        hotPercent = (try? c.decode(Int.self, forKey: .hotPercent)) ?? d.hotPercent
        fineShown = (try? c.decode(Int.self, forKey: .fineShown)) ?? d.fineShown
        relayWaitSeconds = (try? c.decode(Int.self, forKey: .relayWaitSeconds)) ?? d.relayWaitSeconds
        lockAfter = (try? c.decode(LockAfter.self, forKey: .lockAfter)) ?? d.lockAfter
        self = clamped()
    }

    // Out-of-range numbers from an older or hand-edited file fall back to their limits.
    public func clamped() -> AppSettings {
        var s = self
        s.refreshSeconds = min(max(refreshSeconds, Limits.refresh.lowerBound), Limits.refresh.upperBound)
        s.lateMinutes = min(max(lateMinutes, Limits.late.lowerBound), Limits.late.upperBound)
        s.hotPercent = min(max(hotPercent, Limits.hot.lowerBound), Limits.hot.upperBound)
        s.fineShown = min(max(fineShown, Limits.fineShown.lowerBound), Limits.fineShown.upperBound)
        s.relayWaitSeconds = min(max(relayWaitSeconds, Limits.relayWait.lowerBound), Limits.relayWait.upperBound)
        return s
    }

    public var changed: Int {
        let d = AppSettings()
        return [theme != d.theme, refreshSeconds != d.refreshSeconds, lateMinutes != d.lateMinutes, hotPercent != d.hotPercent,
                fineShown != d.fineShown, relayWaitSeconds != d.relayWaitSeconds, lockAfter != d.lockAfter].filter { $0 }.count
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public static func decode(_ data: Data?) -> AppSettings {
        guard let data, let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }
}
