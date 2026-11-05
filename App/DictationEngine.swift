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
    /// Something the user needs to act on.
    @Published private(set) var errorMessage: String?

    static let idleTimeout: TimeInterval = 10 * 60

    private let capture = AudioCapture()
    private let transcriber = Transcriber()
    private let cleaner = Cleaner.onDevice

    private var toggleObserver: DarwinNotifier?
    private var tickTimer: Timer?
    private var lastActivity = Date()
    private var isArming = false
    private var isRestartingAudio = false
    private var modelTask: Task<Void, Never>?
    private var processTask: Task<Void, Never>?
    private var unloadTask: Task<Void, Never>?
    private var notificationTokens: [NSObjectProtocol] = []

    init() {
        Shared.state = .off
        Shared.defaults.set(0.0, forKey: Shared.Key.heartbeat)
        Shared.message = nil
        if !Shared.appGroupAvailable {
            errorMessage = "The App Group \(Shared.appGroup) isn't available. Check signing & capabilities on both targets."
        }
        toggleObserver = DarwinNotifier(name: Shared.Note.toggle) { [weak self] in self?.handleToggle() }
        observeAudio()
    }

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
        guard Shared.appGroupAvailable else {
            errorMessage = "The App Group \(Shared.appGroup) isn't available. Check signing & capabilities on both targets."
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Microphone access is off. Enable it in Settings → Dictation."
            return
        }
        do {
            try capture.startEngine()
        } catch {
            errorMessage = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
        lastActivity = Date()
        setState(.armed, message: nil)
        startTicking()
        loadModel()
    }

    func disarm(message: String? = nil) {
        processTask?.cancel(); processTask = nil
        modelTask?.cancel(); modelTask = nil
        tickTimer?.invalidate(); tickTimer = nil
        capture.stopEngine()
        Shared.defaults.set(0.0, forKey: Shared.Key.heartbeat)
        modelStatus = .notLoaded
        setState(.off, message: message)
        if let message { notice = message }
        let transcriber = self.transcriber
        unloadTask = Task { await transcriber.unload() }
    }

    func toggleArmed() {
        state == .off ? arm() : disarm()
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
        guard capture.isEngineRunning else {
            restartAudio()
            return
        }
        errorMessage = nil
        notice = nil
        lastActivity = Date()
        capture.beginCapture()
        setState(.recording, message: nil)
    }

    private func stopRecording() {
        let samples = capture.endCapture()
        lastActivity = Date()
        setState(.processing, message: nil)
        processTask = Task { [weak self] in await self?.process(samples) }
    }

    private func process(_ samples: [Float]) async {
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
            errorMessage = "Transcription failed: \(error.localizedDescription)"
            finishProcessing(message: "Transcription failed")
        }
    }

    private func finishProcessing(message: String?) {
        lastActivity = Date()
        if state == .processing { setState(.armed, message: message) }
    }

    /// Hands the final text to the keyboard via the App Group and wakes it with a Darwin notification.
    private func deliver(_ text: String) {
        let d = Shared.defaults
        d.set(text, forKey: Shared.Key.resultText)
        d.set(Date().timeIntervalSince1970, forKey: Shared.Key.resultTime)
        d.set(UUID().uuidString, forKey: Shared.Key.resultID)
        DarwinNotifier.post(Shared.Note.resultReady)
    }

    // MARK: - Heartbeat, cap and auto-disarm

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
        if state == .recording, capture.hitCap { stopRecording() }
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
                MainActor.assumeIsolated { self?.restartAudio() }
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

    /// Rebuilds the engine after an interruption, route change or media-services reset.
    private func restartAudio() {
        guard state != .off, !isRestartingAudio else { return }
        isRestartingAudio = true
        defer { isRestartingAudio = false }
        let wasRecording = state == .recording
        capture.stopEngine()
        do {
            try capture.startEngine()
            if wasRecording { setState(.armed, message: "Recording interrupted") }
        } catch {
            disarm(message: "Audio stopped: \(error.localizedDescription)")
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
