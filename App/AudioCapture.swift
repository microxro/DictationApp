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
final class AudioCapture: @unchecked Sendable {
    static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var capturing = false

    /// Hard cap so a stuck recording can't eat memory (5 min of 16 kHz Float32 is ~19 MB).
    static let maxSamples = Int(targetSampleRate) * 300

    var isEngineRunning: Bool { engine.isRunning }

    /// True once the sample cap was hit while capturing.
    var hitCap: Bool { lock.lock(); defer { lock.unlock() }; return samples.count >= Self.maxSamples }

    // MARK: Engine lifecycle

    func startEngine() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)

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
            let converted = AudioResampler.resample(buffer, using: converter, to: target)
            self.append(converted)
        }
        engine.prepare()
        try engine.start()
    }

    func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock(); capturing = false; samples.removeAll(keepingCapacity: false); lock.unlock()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Capture window

    private var isCapturing: Bool { lock.lock(); defer { lock.unlock() }; return capturing }

    func beginCapture() {
        lock.lock(); samples.removeAll(keepingCapacity: true); capturing = true; lock.unlock()
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
}

/// Pure conversion helper (unit tested): any PCM buffer -> 16 kHz mono Float32 samples.
enum AudioResampler {
    static func resample(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter,
                         to target: AVAudioFormat) -> [Float] {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }

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
        guard status != .error, error == nil, let channel = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }
}
