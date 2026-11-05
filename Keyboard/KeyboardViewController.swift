import UIKit

/// Dictation-only keyboard. It never touches the microphone (iPadOS forbids that in extensions);
/// it asks the main app, which holds a live audio session, to record, and inserts the text it sends back.
final class KeyboardViewController: UIInputViewController {
    private let micButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let globeButton = UIButton(type: .system)
    private let spaceButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)
    private let returnButton = UIButton(type: .system)

    private var stateObserver: DarwinNotifier?
    private var resultObserver: DarwinNotifier?
    private var pollTimer: Timer?
    private var deleteDelay: Timer?
    private var deleteRepeat: Timer?
    private var isVisible = false

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        stateObserver = DarwinNotifier(name: Shared.Note.stateChanged) { [weak self] in
            self?.refresh()
            // Cross-process defaults can lag the notification by a moment; a second read settles it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.refresh() }
        }
        resultObserver = DarwinNotifier(name: Shared.Note.resultReady) { [weak self] in
            self?.insertPendingResult()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.insertPendingResult() }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isVisible = true
        refresh()
        insertPendingResult()   // a result may have arrived while this keyboard wasn't visible
        // Re-check regularly while visible so a killed/disarmed app never leaves a stale "ready" button.
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        pollTimer?.invalidate(); pollTimer = nil
        stopDeleteRepeat()
    }

    // MARK: UI

    private func buildUI() {
        view.backgroundColor = .clear

        var micConfig = UIButton.Configuration.filled()
        micConfig.cornerStyle = .capsule
        micConfig.image = UIImage(systemName: "mic.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold))
        micConfig.contentInsets = NSDirectionalEdgeInsets(top: 22, leading: 56, bottom: 22, trailing: 56)
        micButton.configuration = micConfig
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        micButton.accessibilityLabel = "Dictate"

        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 3
        statusLabel.textColor = .secondaryLabel
        statusLabel.adjustsFontForContentSizeCategory = true

        style(globeButton, symbol: "globe")
        globeButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        globeButton.accessibilityLabel = "Next keyboard"

        style(spaceButton, title: "space")
        spaceButton.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)

        style(deleteButton, symbol: "delete.left")
        deleteButton.addTarget(self, action: #selector(deleteDown), for: .touchDown)
        deleteButton.addTarget(self, action: #selector(stopDeleteRepeat), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        deleteButton.accessibilityLabel = "Delete"

        style(returnButton, symbol: "return")
        returnButton.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)
        returnButton.accessibilityLabel = "Return"

        let bottom = UIStackView(arrangedSubviews: [globeButton, spaceButton, deleteButton, returnButton])
        bottom.axis = .horizontal
        bottom.spacing = 8
        bottom.distribution = .fill
        for key in [globeButton, deleteButton, returnButton] {
            key.widthAnchor.constraint(equalToConstant: 64).isActive = true
        }
        bottom.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let column = UIStackView(arrangedSubviews: [statusLabel, micButton, bottom])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 14
        column.translatesAutoresizingMaskIntoConstraints = false
        micButton.setContentHuggingPriority(.defaultHigh, for: .vertical)
        view.addSubview(column)

        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            column.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])

        let height = view.heightAnchor.constraint(equalToConstant: 280)
        height.priority = .defaultHigh
        height.isActive = true
    }

    private func style(_ button: UIButton, symbol: String? = nil, title: String? = nil) {
        var config = UIButton.Configuration.gray()
        config.cornerStyle = .medium
        if let symbol { config.image = UIImage(systemName: symbol) }
        if let title { config.title = title }
        button.configuration = config
    }

    // MARK: State

    private var current: Shared.State { Shared.appIsArmed ? Shared.state : .off }

    private func refresh() {
        guard hasFullAccess else {
            setMic(.off, enabled: false)
            show("Turn on Allow Full Access: Settings → General → Keyboard → Keyboards → Dictation.", error: true)
            return
        }
        guard Shared.appGroupAvailable else {
            setMic(.off, enabled: false)
            show("Setup problem: the App Group isn't available. Reinstall the app with signing set on both targets.", error: true)
            return
        }
        let state = current
        setMic(state, enabled: state != .processing)

        // Any message the app published is shown in every state, including .off (permission denied,
        // audio stopped, auto-disarmed, model failed...).
        if let message = Shared.message, !message.isEmpty {
            show(message, error: false)
            return
        }
        switch state {
        case .off:        show("Tap the mic. The Dictation app opens; swipe back, then tap again.", error: false)
        case .armed:      show("Tap to start dictating", error: false)
        case .recording:  show("Listening… tap to finish", error: false)
        case .processing: show("Writing…", error: false)
        }
    }

    private func setMic(_ state: Shared.State, enabled: Bool) {
        var config = micButton.configuration ?? .filled()
        let symbol: String
        switch state {
        case .off:        config.baseBackgroundColor = .systemGray;   symbol = "mic.slash.fill"
        case .armed:      config.baseBackgroundColor = .systemGreen;  symbol = "mic.fill"
        case .recording:  config.baseBackgroundColor = .systemRed;    symbol = "stop.fill"
        case .processing: config.baseBackgroundColor = .systemPurple; symbol = "ellipsis"
        }
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold))
        micButton.configuration = config
        micButton.isEnabled = enabled
    }

    private func show(_ text: String, error: Bool) {
        statusLabel.textColor = error ? .systemRed : .secondaryLabel
        statusLabel.text = text
    }

    // MARK: Actions

    @objc private func micTapped() {
        guard hasFullAccess else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        switch current {
        case .off:
            openHostApp()
        case .armed, .recording:
            DarwinNotifier.post(Shared.Note.toggle)
        case .processing:
            break
        }
    }

    /// Extensions can't use `UIApplication.shared`, but the responder chain still reaches the host's UIApplication.
    private func openHostApp() {
        guard let url = URL(string: "\(Shared.urlScheme)://start") else { return }
        var responder: UIResponder? = self
        while let r = responder {
            if let application = r as? UIApplication {
                show("Opening Dictation… swipe back when it's ready.", error: false)
                application.open(url, options: [:]) { [weak self] opened in
                    DispatchQueue.main.async {
                        if !opened { self?.show(Self.openFailedText, error: true) }
                    }
                }
                return
            }
            responder = r.next
        }
        show(Self.openFailedText, error: true)
    }

    private static let openFailedText = "Couldn't open the app from here. Open Dictation yourself, tap Arm, then come back."

    private func insertPendingResult() {
        // Only the keyboard actually on screen may claim a result; a hidden instance would swallow it.
        guard isVisible, hasFullAccess else { return }
        let d = Shared.defaults
        let id = d.string(forKey: Shared.Key.resultID)
        guard Shared.shouldInsertResult(id: id, consumedID: d.string(forKey: Shared.Key.consumedID),
                                        resultTime: d.double(forKey: Shared.Key.resultTime)),
              let text = d.string(forKey: Shared.Key.resultText), !text.isEmpty
        else { return }
        let lead = SmartSpacing.leadingSpace(before: textDocumentProxy.documentContextBeforeInput)
        textDocumentProxy.insertText(lead + text + " ")
        d.set(id, forKey: Shared.Key.consumedID)           // mark consumed only after inserting
        d.removeObject(forKey: Shared.Key.resultText)      // don't leave the dictation on disk
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    @objc private func spaceTapped() { textDocumentProxy.insertText(" ") }
    @objc private func returnTapped() { textDocumentProxy.insertText("\n") }

    @objc private func deleteDown() {
        stopDeleteRepeat()   // never stack timers
        textDocumentProxy.deleteBackward()
        deleteDelay = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self else { return }
            // Created directly (no async hop), so a release can always cancel it.
            self.deleteRepeat = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
                self?.textDocumentProxy.deleteBackward()
            }
        }
    }

    @objc private func stopDeleteRepeat() {
        deleteDelay?.invalidate(); deleteDelay = nil
        deleteRepeat?.invalidate(); deleteRepeat = nil
    }
}
