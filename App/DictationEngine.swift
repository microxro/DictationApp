import AVFoundation
import Foundation

enum ModelStatus: Equatable {
    case notLoaded, loading, ready
    case failed(String)
}

/// Coordinates arming (keeping the mic session alive), capture, transcription, cleanup and delivery
/// of the result to the keyboard extension.
@MainActor
final class DictationEngine: ObservableObject {
    @Published private(set) var state: Shared.State = .off
    @Published private(set) var modelStatus: ModelStatus = .notLoaded
    @Published private(set) var lastText = ""
    /// Non-fatal information, e.g. "used raw transcript".
    @Published private(set) var notice: String?
    /// Something the user needs to act on. Also mirrored to the keyboard's status label.
    @Published private(set) var errorMessage: String?

    static let idleTimeout: TimeInterval = 10 * 60

    private let capture = AudioCapture()
    private let transcriber = Transcriber()
    private let cleaner = Cleaner.onDevice

    private var toggleObserver: DarwinNotifier?
    private var tickTimer: Timer?
    private var lastActivity = Date()
    private var lastDelivery: Date?
    private var lastAudioRestart = Date.distantPast
    private var isArming = false
    private var modelTask: Task<Void, Never>?
    private var processTask: Task<Void, Never>?
    private var unloadTask: Task<Void, Never>?
    private var notificationTokens: [NSObjectProtocol] = []

    init() {
        Shared.state = .off
        Shared.defaults.set(0.0, forKey: Shared.Key.heartbeat)
        Shared.defaults.removeObject(forKey: Shared.Key.resultText)
        Shared.message = nil
        if !Shared.appGroupAvailable { errorMessage = Self.appGroupError }
        // Darwin callbacks arrive on the main queue (see DarwinNotifier), so this is safe on the main actor.
        toggleObserver = DarwinNotifier(name: Shared.Note.toggle) { [weak self] in self?.handleToggle() }
        observeAudio()
    }

    private static let appGroupError =
        "The App Group \(Shared.appGroup) isn't available. Check Signing & Capabilities on both targets."

    // MARK: - Arm / disarm

    func arm() {
        guard state == .off, !isArming else { return }
        isArming = true
        errorMessage = nil
        notice = nil
        Task { await armAsync() }
    }

    private func armAsync() async {
        defer { isArming = false }
        guard Shared.appGroupAvailable else { fail(Self.appGroupError); return }
        guard await AVAudioApplication.requestRecordPermission() else {
            fail("Microphone access is off. Enable it in Settings → Dictation.")
            return
        }
        do {
            try capture.startEngine()
        } catch {
            capture.stopEngine()    // don't leak a half-started session or tap
            fail("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }
        lastActivity = Date()
        setState(.armed, message: nil)
        startTicking()
        loadModel()
    }

    func disarm(message: String? = nil) {
        let inFlight = processTask
        inFlight?.cancel(); processTask = nil
        modelTask?.cancel(); modelTask = nil
        tickTimer?.invalidate(); tickTimer = nil
        capture.stopEngine()
        clearResult()
        Shared.defaults.set(0.0, forKey: Shared.Key.heartbeat)
        modelStatus = .notLoaded
        setState(.off, message: message)
        if let message { notice = message }
        // Unload only after any in-flight transcription has finished, never mid-inference.
        let transcriber = self.transcriber
        unloadTask = Task {
            await inFlight?.value
            await transcriber.unload()
        }
    }

    func toggleArmed() {
        state == .off ? arm() : disarm()
    }

    /// Shows a problem in the app and on the keyboard, even while disarmed.
    private func fail(_ message: String) {
        errorMessage = message
        publishMessage(message)
    }

    // MARK: - Model

    func retryModel() {
        guard state != .off else { return }
        errorMessage = nil
        loadModel()
    }

    private func loadModel() {
        modelTask?.cancel()
        modelStatus = .loading
        publishMessage("Loading model…")
        let transcriber = self.transcriber
        let pendingUnload = unloadTask
        modelTask = Task { [weak self] in
            await pendingUnload?.value          // never load while the previous unload is still running
            do {
                try await transcriber.load()
                guard !Task.isCancelled else { return }
                self?.modelDidLoad()
            } catch {
                guard !Task.isCancelled else { return }
                self?.modelDidFail(error)
            }
        }
    }

    private func modelDidLoad() {
        modelStatus = .ready
        if state == .armed { publishMessage(nil) }
    }

    private func modelDidFail(_ error: Error) {
        modelStatus = .failed(error.localizedDescription)
        errorMessage = "The speech model failed to load: \(error.localizedDescription)"
        publishMessage("Model failed — open the Dictation app")
    }

    // MARK: - Keyboard toggle

    private func handleToggle() {
        switch state {
        case .armed: startRecording()
        case .recording: stopRecording()
        case .processing, .off: break
        }
    }

    private func startRecording() {
        if !capture.isEngineRunning, !restartAudio() { return }
        errorMessage = nil
        notice = nil
        lastActivity = Date()
        capture.beginCapture()
        setState(.recording, message: nil)
    }

    private func stopRecording() {
        let samples = capture.endCapture()
        let conversionFailures = capture.conversionFailures
        lastActivity = Date()
        setState(.processing, message: nil)
        processTask = Task { [weak self] in
            await self?.process(samples, conversionFailures: conversionFailures)
        }
    }

    private func process(_ samples: [Float], conversionFailures: Int) async {
        if samples.count < Transcriber.minSamples {
            if conversionFailures > 0 {
                errorMessage = "Microphone audio couldn't be converted (\(conversionFailures) buffers failed). Try disarming and arming again."
                finishProcessing(message: "Microphone conversion failed")
            } else {
                finishProcessing(message: "Too short — try again")
            }
            return
        }
        if AudioLevel.isSilent(samples) {
            finishProcessing(message: "Didn't hear anything")
            return
        }
        do {
            let raw = try await transcriber.transcribe(samples)
            try Task.checkCancellation()
            guard !raw.isEmpty else {
                finishProcessing(message: "Didn't catch anything")
                return
            }
            let result = await cleaner.clean(raw)
            try Task.checkCancellation()
            guard !result.text.isEmpty else {
                finishProcessing(message: "Didn't catch anything")
                return
            }
            lastText = result.text
            notice = result.fallbackReason.map { "Inserted the raw transcript (\($0))." }
            modelStatus = .ready
            deliver(result.text)
            finishProcessing(message: nil)
        } catch is CancellationError {
            // disarm() already reset everything
        } catch TranscriberError.tooShort {
            finishProcessing(message: "Too short — try again")
        } catch {
            guard !Task.isCancelled, state == .processing else { return }   // disarmed meanwhile: not a real error
            errorMessage = "Transcription failed: \(error.localizedDescription)"
            finishProcessing(message: "Transcription failed")
        }
    }

    private func finishProcessing(message: String?) {
        lastActivity = Date()
        if state == .processing { setState(.armed, message: message) }
    }

    // MARK: - Result delivery

    /// Hands the final text to the keyboard via the App Group and wakes it with a Darwin notification.
    private func deliver(_ text: String) {
        let d = Shared.defaults
        d.set(text, forKey: Shared.Key.resultText)
        d.set(Date().timeIntervalSince1970, forKey: Shared.Key.resultTime)
        d.set(UUID().uuidString, forKey: Shared.Key.resultID)
        lastDelivery = Date()
        DarwinNotifier.post(Shared.Note.resultReady)
    }

    /// Dictations can be private: don't leave the text in the shared plist.
    private func clearResult() {
        Shared.defaults.removeObject(forKey: Shared.Key.resultText)
        lastDelivery = nil
    }

    // MARK: - Heartbeat, cap, expiry and auto-disarm

    private func startTicking() {
        tickTimer?.invalidate()
        publishHeartbeat()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func tick() {
        guard state != .off else { return }
        publishHeartbeat()
        if let lastDelivery, Date().timeIntervalSince(lastDelivery) > Shared.resultMaxAge { clearResult() }
        if state == .recording, capture.hitCap { stopRecording() }
        // A slow first-run model download isn't "idle".
        if modelStatus == .loading { lastActivity = Date() }
        if state == .armed, Date().timeIntervalSince(lastActivity) > Self.idleTimeout {
            disarm(message: "Disarmed after 10 minutes without dictation.")
        }
    }

    private func publishHeartbeat() {
        Shared.defaults.set(Date().timeIntervalSince1970, forKey: Shared.Key.heartbeat)
    }

    // MARK: - Audio interruptions & route changes

    private func observeAudio() {
        let nc = NotificationCenter.default
        notificationTokens.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            MainActor.assumeIsolated { self?.audioInterruption(type) }
        })
        for name in [Notification.Name.AVAudioEngineConfigurationChange, AVAudioSession.mediaServicesWereResetNotification] {
            notificationTokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Our own restart can itself post a configuration change; don't loop.
                    guard let self, Date().timeIntervalSince(self.lastAudioRestart) > 1 else { return }
                    self.restartAudio()
                }
            })
        }
    }

    private func audioInterruption(_ type: AVAudioSession.InterruptionType?) {
        guard state != .off else { return }
        switch type {
        case .began:
            if state == .recording {
                _ = capture.endCapture()
                setState(.armed, message: "Recording interrupted")
            }
        case .ended:
            restartAudio()
        default:
            break
        }
    }

    /// Rebuilds the engine (keeping the session active). Returns false if it failed, in which case the app disarmed.
    @discardableResult
    private func restartAudio() -> Bool {
        guard state != .off else { return false }
        lastAudioRestart = Date()
        let wasRecording = state == .recording
        do {
            try capture.restartEngine()
            if wasRecording {
                _ = capture.endCapture()
                setState(.armed, message: "Recording interrupted")
            }
            return true
        } catch {
            disarm(message: "Audio stopped: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Shared state publishing

    private func setState(_ new: Shared.State, message: String?) {
        state = new
        Shared.state = new
        Shared.message = message
        DarwinNotifier.post(Shared.Note.stateChanged)
    }

    private func publishMessage(_ message: String?) {
        Shared.message = message
        DarwinNotifier.post(Shared.Note.stateChanged)
    }
}
