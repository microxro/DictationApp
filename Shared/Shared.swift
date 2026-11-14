import Foundation

/// Constants and IPC shared by the app and the keyboard extension.
///
/// All cross-process data goes through the App Group suite (never `UserDefaults.standard`,
/// which is private to each process). Signals go through Darwin notifications, which carry no payload.
enum Shared {
    static let appGroup = "group.com.pranav.dictation"
    static let urlScheme = "dictation"

    /// Shared defaults, created once. Falls back to `.standard` only if the App Group is misconfigured, so the
    /// app never crashes — but then the keyboard cannot see anything, and both sides show a setup error.
    /// (`UserDefaults(suiteName:)` returns non-nil even without the entitlement, so it can't detect that.)
    static let defaults: UserDefaults = UserDefaults(suiteName: appGroup) ?? .standard

    /// True only when the App Group container exists, i.e. the entitlement is really granted to this process.
    static var appGroupAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil
    }

    enum Key {
        static let heartbeat = "heartbeat"       // Double, unix time; written by the app every second while armed
        static let state = "state"               // State.rawValue
        static let message = "message"           // String, short status/error for the keyboard to show
        static let resultText = "resultText"
        static let resultID = "resultID"
        static let resultTime = "resultTime"     // Double, unix time the result was produced
        static let consumedID = "consumedID"     // resultID the keyboard has already inserted
    }

    enum Note {
        static let toggle = "com.pranav.dictation.toggle"           // keyboard -> app
        static let stateChanged = "com.pranav.dictation.state"      // app -> keyboard
        static let resultReady = "com.pranav.dictation.result"      // app -> keyboard
    }

    enum State: String {
        case off, armed, recording, processing
    }

    /// How old a heartbeat may be before the app is considered gone.
    static let heartbeatTimeout: TimeInterval = 3
    /// A result older than this is never inserted, and the app erases the stored text after this long
    /// (dictations can be private; they shouldn't sit in the shared plist).
    static let resultMaxAge: TimeInterval = 30

    // MARK: Pure helpers (unit tested)

    static func isHeartbeatFresh(_ heartbeat: Double, now: Double = Date().timeIntervalSince1970,
                                 timeout: TimeInterval = heartbeatTimeout) -> Bool {
        guard heartbeat > 0 else { return false }
        let age = now - heartbeat
        return age >= -1 && age < timeout   // tolerate tiny clock skew, reject far-future values
    }

    static func shouldInsertResult(id: String?, consumedID: String?, resultTime: Double,
                                   now: Double = Date().timeIntervalSince1970) -> Bool {
        guard let id, !id.isEmpty, id != consumedID else { return false }
        let age = now - resultTime
        return age >= -1 && age < resultMaxAge
    }

    // MARK: Convenience accessors

    static var appIsArmed: Bool { isHeartbeatFresh(defaults.double(forKey: Key.heartbeat)) }

    static var state: State {
        get { State(rawValue: defaults.string(forKey: Key.state) ?? "") ?? .off }
        set { defaults.set(newValue.rawValue, forKey: Key.state) }
    }

    static var message: String? {
        get { defaults.string(forKey: Key.message) }
        set { defaults.set(newValue, forKey: Key.message) }
    }
}

/// Decides whether a space is needed before inserted text so it doesn't glue onto the previous word.
enum SmartSpacing {
    static func leadingSpace(before context: String?) -> String {
        guard let context, let last = context.last else { return "" }
        if last.isWhitespace || last.isNewline { return "" }
        if "([{\u{201C}\u{2018}".contains(last) { return "" }
        // A straight quote is ambiguous: an odd count means we are inside a quotation (it just opened).
        if last == "\"" { return context.filter { $0 == "\"" }.count % 2 == 1 ? "" : " " }
        return " "
    }
}

/// Cross-process signalling via Darwin notifications (no payload; data goes through the App Group).
/// Keep a strong reference to an instance for as long as you want callbacks. Callbacks run on the main queue.
final class DarwinNotifier {
    private let name: String
    fileprivate let handler: () -> Void

    init(name: String, handler: @escaping () -> Void) {
        self.name = name
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<DarwinNotifier>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { me.handler() }
            },
            name as CFString, nil, .deliverImmediately)
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
    }

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }
}
