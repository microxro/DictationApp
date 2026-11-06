import CoreML
import Foundation
import WhisperKit

/// Wraps WhisperKit (pinned to 1.1.1 in project.yml; API checked against that tag's source).
/// The model loads once per arm and is released on disarm to keep memory low.
actor Transcriber {
    /// Change this one constant to use a different model. Names must match a folder in
    /// huggingface.co/argmaxinc/whisperkit-coreml (a substring is enough; it is matched as `*name/*`).
    /// Smaller/faster alternatives: "small", "distil-large-v3_594MB".
    static let modelName = "large-v3-v20240930_turbo_632MB"

    /// Fewer than ~0.4 s of audio is treated as an accidental tap. Enforced once, by the caller.
    static let minSamples = Int(AudioCapture.targetSampleRate * 0.4)

    private var loadTask: Task<WhisperKit, Error>?

    /// Starts loading (downloads the model on first run). Safe to call repeatedly.
    func load() async throws {
        _ = try await pipeline()
    }

    func unload() async {
        guard let task = loadTask else { return }
        loadTask = nil
        task.cancel()                       // abort an in-flight download/load if there is one
        let pipe = try? await task.value
        if let pipe { await pipe.unloadModels() }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let pipe = try await pipeline()
        // Language and special-token handling are explicit so a library default change can't alter behaviour.
        let options = DecodingOptions(verbose: false, task: .transcribe, language: "en", skipSpecialTokens: true)
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        let raw = results.map(\.text).joined(separator: " ")
        return TranscriptSanitizer.clean(raw)
    }

    private func pipeline() async throws -> WhisperKit {
        if let loadTask { return try await loadTask.value }
        let task = Task { () throws -> WhisperKit in
            // WhisperKit's default runs the mel-spectrogram model on the GPU, which iOS forbids while the app is
            // in the background — exactly where dictation happens. CPU for mel; the encoder/decoder use the Neural Engine.
            let compute = ModelComputeOptions(melCompute: .cpuOnly)
            let config = WhisperKitConfig(model: Self.modelName, computeOptions: compute,
                                          verbose: false, prewarm: true, load: true, download: true)
            return try await WhisperKit(config)
        }
        loadTask = task
        do {
            return try await task.value
        } catch {
            if loadTask == task { loadTask = nil }   // allow a retry; never wipe a newer load's task
            throw error
        }
    }
}

/// Removes Whisper artifacts like "[BLANK_AUDIO]" and "<|endoftext|>" and collapses whitespace.
/// Parentheses are left alone: a user can legitimately dictate them.
enum TranscriptSanitizer {
    static func clean(_ text: String) -> String {
        var out = text
        for pattern in [#"\[[^\]]*\]"#, #"<\|[^|]*\|>"#] {
            out = out.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
