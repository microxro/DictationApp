import AVFoundation

enum CaptureError: LocalizedError {
    case noInput, converterUnavailable

    var errorDescription: String? {
        switch self {
        case .noInput: return "No microphone input is available."
        case .converterUnavailable: return "Couldn't set up audio conversion to 16 kHz."
        }
    }
}

/// Owns the audio session and engine. While the engine runs, the app stays alive in the background;
/// the tap discards audio unless `beginCapture()` has been called.
///
/// Deliberately NOT @MainActor: the tap runs on a realtime audio thread and must not touch main-actor state.
/// Engine lifecycle methods are called from the main thread only; the sample buffer is guarded by a lock.
final class AudioCapture: @unchecked Sendable {
    static let targetSampleRate: Double = 16_000

    /// Hard cap so a stuck recording can't eat memory (5 min of 16 kHz Float32 is ~19 MB).
    static let maxSamples = Int(targetSampleRate) * 300

    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var capturing = false
    private var failures = 0

    var isEngineRunning: Bool { engine.isRunning }
    var hitCap: Bool { lock.lock(); defer { lock.unlock() }; return samples.count >= Self.maxSamples }
    /// Buffers that failed to convert since `beginCapture()`.
    var conversionFailures: Int { lock.lock(); defer { lock.unlock() }; return failures }

    // MARK: Engine lifecycle

    func startEngine() throws {
        try configureSession(activate: true)
        try buildAndStart()
    }

    /// Rebuilds the engine after an interruption, route change or media-services reset.
    /// Keeps the audio session active: deactivating it would make iOS refuse to start recording again
    /// from the background. A fresh AVAudioEngine is required after a media-services reset.
    func restartEngine() throws {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        try configureSession(activate: false)
        try AVAudioSession.sharedInstance().setActive(true)   // surface the real cause if the session is still held
        try buildAndStart()
    }

    func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); capturing = false; samples.removeAll(keepingCapacity: false); lock.unlock()
        // Deactivation fails only if another client still uses audio; nothing the user can act on, so it is ignored on purpose.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func configureSession(activate: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        // A2DP keeps music on AirPods/headphones at full quality. The Bluetooth *mic* (HFP) is deliberately
        // not enabled: while armed it would force headphones into low-quality call mode. The iPad's own mic is used.
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothA2DP])
        if activate { try session.setActive(true) }
    }

    private func buildAndStart() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw CaptureError.noInput }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.targetSampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: target)
        else { throw CaptureError.converterUnavailable }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            guard let self, self.isCapturing else { return }
            if let converted = AudioResampler.resample(buffer, using: converter, to: target) {
                self.append(converted)
            } else {
                self.noteFailure()
            }
        }
        engine.prepare()
        try engine.start()
    }

    // MARK: Capture window

    private var isCapturing: Bool { lock.lock(); defer { lock.unlock() }; return capturing }

    func beginCapture() {
        lock.lock(); samples.removeAll(keepingCapacity: true); failures = 0; capturing = true; lock.unlock()
    }

    /// Stops capturing and returns everything recorded since `beginCapture()`.
    func endCapture() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        capturing = false
        let out = samples
        samples.removeAll(keepingCapacity: false)
        return out
    }

    private func append(_ new: [Float]) {
        guard !new.isEmpty else { return }
        lock.lock()
        if samples.count < Self.maxSamples { samples.append(contentsOf: new) }
        lock.unlock()
    }

    private func noteFailure() {
        lock.lock(); failures += 1; lock.unlock()
    }
}

/// Pure conversion helper (unit tested): any PCM buffer -> 16 kHz mono Float32 samples.
/// Returns nil when conversion itself failed (distinct from "converted, but no output yet").
enum AudioResampler {
    static func resample(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter,
                         to target: AVAudioFormat) -> [Float]? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil else { return nil }
        guard let channel = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }
}

/// Pure level check (unit tested). Whisper tends to hallucinate text ("Thank you.") on silence.
enum AudioLevel {
    static let silenceThreshold: Float = 0.003

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for v in samples { sum += v * v }
        return (sum / Float(samples.count)).squareRoot()
    }

    static func isSilent(_ samples: [Float]) -> Bool { rms(samples) < silenceThreshold }
}
