import Foundation

/// Constants and IPC shared by the app and the keyboard extension.
enum Shared {
    static let appGroup = "group.com.pranav.dictation"
    static let urlScheme = "dictation"

    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup)! }

    enum Key {
        static let heartbeat = "heartbeat"     // Double, unix time; app writes every second while armed
        static let state = "state"             // State.rawValue
        static let resultText = "resultText"
        static let resultID = "resultID"
    }

    enum Note {
        static let toggle = "com.pranav.dictation.toggle"           // keyboard -> app
        static let stateChanged = "com.pranav.dictation.state"      // app -> keyboard
        static let resultReady = "com.pranav.dictation.result"      // app -> keyboard
    }

    enum State: String {
        case off, armed, recording, processing
    }

    /// True if the app's audio session is alive (heartbeat fresh).
    static var appIsArmed: Bool {
        Date().timeIntervalSince1970 - defaults.double(forKey: Key.heartbeat) < 3
    }

    static var state: State {
        get { State(rawValue: defaults.string(forKey: Key.state) ?? "") ?? .off }
        set { defaults.set(newValue.rawValue, forKey: Key.state) }
    }
}

/// Cross-process signalling via Darwin notifications (no payload; data goes through the App Group).
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
