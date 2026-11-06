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

    func testSmartSpacing() {
        XCTAssertEqual(SmartSpacing.leadingSpace(before: nil), "")
        XCTAssertEqual(SmartSpacing.leadingSpace(before: ""), "")
        XCTAssertEqual(SmartSpacing.leadingSpace(before: "hello"), " ")
        XCTAssertEqual(SmartSpacing.leadingSpace(before: "End."), " ")
        XCTAssertEqual(SmartSpacing.leadingSpace(before: "hello "), "")
        XCTAssertEqual(SmartSpacing.leadingSpace(before: "line\n"), "")
        XCTAssertEqual(SmartSpacing.leadingSpace(before: "("), "")
        XCTAssertEqual(SmartSpacing.leadingSpace(before: "say \""), "")             // just opened a quote
        XCTAssertEqual(SmartSpacing.leadingSpace(before: "He said \"hello\""), " ")  // closed a quote
        XCTAssertEqual(SmartSpacing.leadingSpace(before: "He said \u{201C}hi\u{201D}"), " ")
    }
}

final class CleanerTests: XCTestCase {
    private struct Boom: Error {}

    func testUsesCleanedTextWhenBackendSucceeds() async {
        let cleaner = Cleaner(backend: { _ in "Hello, world." })
        let result = await cleaner.clean("um hello world")
        XCTAssertEqual(result, CleanResult(text: "Hello, world.", fallbackReason: nil))
    }

    func testSelfCorrectionResolvedByModelIsAccepted() async {
        let cleaner = Cleaner(backend: { _ in "The answer is green." })
        let result = await cleaner.clean("um i think the answer is like uh blue no wait i mean green")
        XCTAssertEqual(result.text, "The answer is green.")
        XCTAssertNil(result.fallbackReason)
    }

    func testGrammarFixesThatChangeWordsAreAccepted() async {
        let cleaner = Cleaner(backend: { _ in "I'm going to go to the store." })
        let result = await cleaner.clean("i am gonna go to the store")
        XCTAssertNil(result.fallbackReason)
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

    func testFallsBackWhenModelRefuses() async {
        let cleaner = Cleaner(backend: { _ in "I can't help with that." })
        let result = await cleaner.clean("what is the capital of france")
        XCTAssertEqual(result.text, "what is the capital of france")
        XCTAssertNotNil(result.fallbackReason)
    }

    func testFallsBackWhenModelGivesShortAnswer() async {
        let cleaner = Cleaner(backend: { _ in "The capital of France is Paris." })
        let result = await cleaner.clean("what is the capital of france")
        XCTAssertEqual(result.text, "what is the capital of france", "a one-word answer must not be inserted")
        XCTAssertNotNil(result.fallbackReason)
    }

    func testCurlyApostropheContractionsAreAccepted() async {
        let cleaner = Cleaner(backend: { _ in "I don\u{2019}t know what I\u{2019}m doing." })
        let result = await cleaner.clean("i don't know what i'm doing")
        XCTAssertNil(result.fallbackReason)
        XCTAssertEqual(result.text, "I don\u{2019}t know what I\u{2019}m doing.")
    }

    func testWordNormalization() {
        XCTAssertEqual(Cleaner.words("I'm gonna go"), ["i", "am", "going", "to", "go"])
        XCTAssertEqual(Cleaner.words("don\u{2019}t Can't it's John's"), ["do", "not", "can", "not", "it", "is", "john"])
    }

    func testFallsBackWhenModelAnswersAtLength() async {
        let cleaner = Cleaner(backend: { _ in "The capital of France is Paris, a city known for the Eiffel Tower." })
        let result = await cleaner.clean("what is the capital of france")
        XCTAssertEqual(result.text, "what is the capital of france")
        XCTAssertNotNil(result.fallbackReason)
    }

    func testPromptDelimitsDictationAndTagsAreStripped() async {
        let seen = PromptBox()
        let cleaner = Cleaner(backend: { prompt in
            await seen.set(prompt)
            return "<dictation>Hello world.</dictation>"
        })
        let result = await cleaner.clean("hello world")
        let prompt = await seen.value
        XCTAssertEqual(prompt, "<dictation>\nhello world\n</dictation>")
        XCTAssertEqual(result.text, "Hello world.")
    }

    func testEmptyAndTinyInputSkipTheModel() async {
        let cleaner = Cleaner(backend: { _ in XCTFail("backend should not be called"); return "" })
        let empty = await cleaner.clean("   ")
        XCTAssertEqual(empty.text, "")
        let tiny = await cleaner.clean("ok")
        XCTAssertEqual(tiny.text, "ok")
    }
}

private actor PromptBox {
    private(set) var value: String?
    func set(_ v: String) { value = v }
}

final class TranscriptSanitizerTests: XCTestCase {
    func testStripsWhisperArtifactsButKeepsParentheses() {
        XCTAssertEqual(TranscriptSanitizer.clean(" [BLANK_AUDIO] hello  <|endoftext|> world "), "hello world")
        XCTAssertEqual(TranscriptSanitizer.clean("see (below) for more"), "see (below) for more")
        XCTAssertEqual(TranscriptSanitizer.clean("[MUSIC]"), "")
    }
}

final class AudioTests: XCTestCase {
    func testResamples48kTo16kMono() throws {
        let inFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let outFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let converter = try XCTUnwrap(AVAudioConverter(from: inFormat, to: outFormat))
        let frames: AVAudioFrameCount = 4_800   // 100 ms
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try XCTUnwrap(buffer.floatChannelData)[0]
        for i in 0..<Int(frames) { channel[i] = sin(2 * .pi * 440 * Float(i) / 48_000) * 0.5 }

        let out = try XCTUnwrap(AudioResampler.resample(buffer, using: converter, to: outFormat))
        // 100 ms at 16 kHz is 1600 samples; allow converter latency/priming slack.
        XCTAssertGreaterThan(out.count, 1_400)
        XCTAssertLessThanOrEqual(out.count, 1_700)
        XCTAssertGreaterThan(out.map(abs).max() ?? 0, 0.2, "signal should survive conversion")
    }

    func testSilenceDetection() {
        XCTAssertTrue(AudioLevel.isSilent([]))
        XCTAssertTrue(AudioLevel.isSilent([Float](repeating: 0.0005, count: 16_000)))
        let speechLike = (0..<16_000).map { sin(2 * .pi * 200 * Float($0) / 16_000) * 0.1 }
        XCTAssertFalse(AudioLevel.isSilent(speechLike))
    }
}
