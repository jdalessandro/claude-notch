import Foundation

/// User-configurable behavior and appearance. Persisted as one JSON blob so new settings can be added
/// without migrations: decoding is tolerant, so missing keys, unknown keys and invalid values all fall
/// back to defaults instead of resetting everything.
public struct Preferences: Codable, Equatable, Sendable {
    /// How the usage card shows plan consumption; a quick toggle on the card itself.
    public enum UsageDisplay: String, Codable, CaseIterable, Sendable { case percent, tokens }
    public enum CostDisplay: String, Codable, CaseIterable, Sendable { case auto, always, never }
    public enum SessionRetention: String, Codable, CaseIterable, Sendable {
        case oneHour, fourHours, twelveHours, oneDay
        public var seconds: TimeInterval {
            switch self {
            case .oneHour: 3600;
            case .fourHours: 4 * 3600;
            case .twelveHours: 12 * 3600;
            case .oneDay: 86_400
            }
        }
    }

    // Appearance
    public var showPrompt = true
    public var showSubagents = true
    public var showContextMeter = true
    public var showUsageCard = true
    // Behavior
    public var autoExpandOnEvents = true
    public var sessionRetention = SessionRetention.twelveHours
    // Notifications
    public var soundEnabled = true
    public var systemNotifications = true
    public var notifyOnPermission = true
    public var notifyOnInput = true
    public var notifyOnFinished = true
    public var notifyOnFailed = true
    // Permissions & usage
    public var approveFromIsland = true
    public var costDisplay = CostDisplay.auto
    public var usageDisplay = UsageDisplay.percent
    /// Include command text / prompt snippets in system banners (they can appear on a locked screen).
    public var bannerDetails = true
    // Advanced
    public var logRawEvents = false

    public init() {}

    public func shouldNotify(_ kind: SessionStore.NotifyKind) -> Bool {
        switch kind {
        case .permission: notifyOnPermission
        case .input: notifyOnInput
        case .finished: notifyOnFinished
        case .failed: notifyOnFailed
        }
    }

    // MARK: tolerant decoding

    private struct AnyKey: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: AnyKey.self)
        func load<T: Decodable>(_ kp: WritableKeyPath<Preferences, T>, _ key: String) {
            if let v = try? c.decode(T.self, forKey: AnyKey(key)) { self[keyPath: kp] = v }
        }
        load(\.showPrompt, "showPrompt"); load(\.showSubagents, "showSubagents")
        load(\.showContextMeter, "showContextMeter"); load(\.showUsageCard, "showUsageCard")
        load(\.autoExpandOnEvents, "autoExpandOnEvents")
        load(\.sessionRetention, "sessionRetention")
        load(\.soundEnabled, "soundEnabled"); load(\.systemNotifications, "systemNotifications")
        load(\.notifyOnPermission, "notifyOnPermission"); load(\.notifyOnInput, "notifyOnInput")
        load(\.notifyOnFinished, "notifyOnFinished"); load(\.notifyOnFailed, "notifyOnFailed")
        load(\.approveFromIsland, "approveFromIsland"); load(\.costDisplay, "costDisplay"); load(\.usageDisplay, "usageDisplay");
        load(\.bannerDetails, "bannerDetails")
        load(\.logRawEvents, "logRawEvents")
    }

    // MARK: persistence

    public static let defaultsKey = "preferences.v1"

    public static func load(_ d: UserDefaults = .standard) -> Preferences {
        if let data = d.data(forKey: defaultsKey), let p = try? JSONDecoder().decode(Preferences.self, from: data) { return p }
        return migrateLegacy(d)
    }

    public func save(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.defaultsKey) }
    }

    /// First launch after the settings panel was introduced: carry over the individual keys it replaces.
    static func migrateLegacy(_ d: UserDefaults) -> Preferences {
        var p = Preferences()
        if let v = d.object(forKey: "interactive") as? Bool { p.approveFromIsland = v }
        if let v = d.object(forKey: "sound") as? Bool { p.soundEnabled = v }
        if let v = d.string(forKey: "costMode"), let m = CostDisplay(rawValue: v) { p.costDisplay = m }
        return p
    }
}
