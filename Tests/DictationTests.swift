import AVFoundation
import XCTest
@testable import Dictation

final class SharedLogicTests: XCTestCase {
    func testHeartbeatFreshness() {
        let now = 1_000.0
        XCTAssertTrue(Shared.isHeartbeatFresh(999.5, now: now))
        XCTAssertTrue(Shared.isHeartbeatFresh(997.5, now: now))
        XCTAssertFalse(Shared.isHeartbeatFresh(996.9, now: now))     // older than 3 s
        XCTAssertFalse(Shared.isHeartbeatFresh(0, now: now))         // disarmed marker
        XCTAssertFalse(Shared.isHeartbeatFresh(5_000, now: now))     // far-future clock garbage
    }

    func testResultInsertionRules() {
        let now = 1_000.0
        XCTAssertTrue(Shared.shouldInsertResult(id: "a", consumedID: nil, resultTime: 990, now: now))
        XCTAssertFalse(Shared.shouldInsertResult(id: "a", consumedID: "a", resultTime: 990, now: now), "already inserted")
        XCTAssertFalse(Shared.shouldInsertResult(id: "a", consumedID: nil, resultTime: 900, now: now), "stale")
        XCTAssertFalse(Shared.shouldInsertResult(id: nil, consumedID: nil, resultTime: 990, now: now))
        XCTAssertFalse(Shared.shouldInsertResult(id: "", consumedID: nil, resultTime: 990, now: now))
    }
}

final class CleanerTests: XCTestCase {
    private struct Boom: Error {}

    func testUsesCleanedTextWhenBackendSucceeds() async {
        let cleaner = Cleaner(backend: { _ in "Hello, world." })
        let result = await cleaner.clean("um hello world")
        XCTAssertEqual(result, CleanResult(text: "Hello, world.", fallbackReason: nil))
    }

    func testFallsBackToRawWhenBackendThrows() async {
        let cleaner = Cleaner(backend: { _ in throw Boom() })
        let result = await cleaner.clean("um hello world")
        XCTAssertEqual(result.text, "um hello world")
        XCTAssertNotNil(result.fallbackReason)
    }

    func testFallsBackWhenBackendReturnsNothing() async {
        let cleaner = Cleaner(backend: { _ in "   \n" })
        let result = await cleaner.clean("hello there")
        XCTAssertEqual(result.text, "hello there")
        XCTAssertNotNil(result.fallbackReason)
    }

    func testFallsBackWhenOutputBalloons() async {
        let long = String(repeating: "blah ", count: 200)
        let cleaner = Cleaner(backend: { _ in long })
        let result = await cleaner.clean("what is the capital of france")
        XCTAssertEqual(result.text, "what is the capital of france")
        XCTAssertNotNil(result.fallbackReason)
    }

    func testEmptyAndTinyInputSkipTheModel() async {
        let cleaner = Cleaner(backend: { _ in XCTFail("backend should not be called"); return "" })
        let empty = await cleaner.clean("   ")
        XCTAssertEqual(empty.text, "")
        let tiny = await cleaner.clean("ok")
        XCTAssertEqual(tiny.text, "ok")
    }
}

final class TranscriptSanitizerTests: XCTestCase {
    func testStripsWhisperArtifactsButKeepsParentheses() {
        XCTAssertEqual(TranscriptSanitizer.clean(" [BLANK_AUDIO] hello  <|endoftext|> world "), "hello world")
        XCTAssertEqual(TranscriptSanitizer.clean("see (below) for more"), "see (below) for more")
        XCTAssertEqual(TranscriptSanitizer.clean("[MUSIC]"), "")
    }
}

final class AudioResamplerTests: XCTestCase {
    func testResamples48kTo16kMono() throws {
        let inFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let outFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let converter = try XCTUnwrap(AVAudioConverter(from: inFormat, to: outFormat))
        let frames: AVAudioFrameCount = 4_800   // 100 ms
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try XCTUnwrap(buffer.floatChannelData)[0]
        for i in 0..<Int(frames) { channel[i] = sin(2 * .pi * 440 * Float(i) / 48_000) * 0.5 }

        let out = AudioResampler.resample(buffer, using: converter, to: outFormat)
        // 100 ms at 16 kHz is 1600 samples; allow converter latency/priming slack.
        XCTAssertGreaterThan(out.count, 1_400)
        XCTAssertLessThanOrEqual(out.count, 1_700)
        XCTAssertGreaterThan(out.map(abs).max() ?? 0, 0.2, "signal should survive conversion")
    }
}
