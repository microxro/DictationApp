# Dictation

Free, fully on-device, Wispr Flow-style voice dictation for iPad. Speech is transcribed locally with
[WhisperKit](https://github.com/argmaxinc/WhisperKit) and cleaned up locally with Apple's on-device
Foundation Models. No cloud, no account, no analytics.

> **Status: written but never compiled or run.** This code was produced without access to Xcode or a device.
> It passed a syntax parse and a manual review, nothing more. Expect a round of fixing build errors and
> on-device quirks. See [What to verify first](#what-to-verify-first).

## How it works

iPadOS forbids microphone use inside keyboard extensions, so the work is split:

| Piece | Job |
|---|---|
| **App** (`App/`) | Holds a live audio session while "armed", records, transcribes (WhisperKit), cleans (Foundation Models), hands the text back. |
| **Keyboard** (`Keyboard/`) | Dictation-only keyboard. Mic button, globe, space, delete, return. Inserts text via `textDocumentProxy`. Never touches the mic. |
| **Shared** (`Shared/`) | App Group defaults for data, Darwin notifications for signals, heartbeat logic. |

Flow: mic tap → keyboard posts `toggle` → app starts/stops capture → transcribe → clean → app writes
`resultText`/`resultID` to the App Group and posts `resultReady` → keyboard inserts the text.
If the app isn't armed (no fresh heartbeat), the keyboard opens `dictation://start` and the app arms itself; you
swipe back and tap again. After that it's instant until the app disarms.

## Mac setup

1. Install Xcode 26+ and XcodeGen: `brew install xcodegen`
2. `git clone` this repo, `cd` into it, run `xcodegen generate` → creates `Dictation.xcodeproj`
3. Open it. For **both** targets (`Dictation`, `DictationKeyboard`): Signing & Capabilities → pick your paid team.
   Automatic signing registers the App Group `group.com.pranav.dictation` for you. If you change the bundle
   prefix, change the group name in `project.yml` **and** `Shared/Shared.swift`.
4. Plug in the iPad (Developer Mode on), choose it as the destination, Run. First launch downloads the Whisper
   model (~630 MB) when you arm; keep the app open on Wi-Fi.
5. On the iPad: Settings → General → Keyboard → Keyboards → Add New Keyboard → **Dictation**, then tap it and turn on
   **Allow Full Access** (required for the App Group; nothing leaves the device).
6. Run the unit tests with ⌘U (target `DictationTests`).

## Daily use

1. Open Dictation, tap **Arm microphone** (or just tap the mic on the keyboard; it opens the app for you).
2. In any text field, hold 🌐 and pick **Dictation**.
3. Tap the mic → speak → tap again. Text appears with a trailing space.
4. The app disarms itself after 10 idle minutes (clears the orange mic dot). Or disarm it manually.

## Known limits (Apple's rules, not bugs)

- The first mic tap after the app disarms (or iPadOS kills it) opens the app; swipe back and tap again.
- The orange microphone indicator is on whenever the app is armed.
- Password and other secure fields never allow custom keyboards.
- It's a separate keyboard: switch to it with 🌐. v1 has no QWERTY layout.
- iPadOS can kill the background session under memory pressure.
- Transcription is set to English. For other languages, change `DecodingOptions` in `Transcriber.swift`.

## Configuration

- Model: `Transcriber.modelName` (one constant). Smaller/faster: `"small"` or `"distil-large-v3_594MB"`.
- Idle timeout: `DictationEngine.idleTimeout`.

## What to verify first

1. **Build.** Fix whatever Xcode flags; most likely spots are WhisperKit/FoundationModels API drift and Swift concurrency warnings.
2. **Arm and record in the app itself** using the "Try it here" field: arm, switch to the Dictation keyboard, tap mic, speak, tap again. Text should appear.
3. **Background:** arm, switch to Notes, use the keyboard there. If the first tap always bounces you to the app, the
   audio session isn't surviving in the background (check the `audio` background mode and the orange dot).
4. **Unverified API assumptions** (written from source/memory, never compiled): `LanguageModelSession(instructions:)` +
   `respond(to:).content`, `SystemLanguageModel.default.availability`, `UIApplication.open` reached through the
   responder chain from the extension, and the Darwin-notification cross-process timing.
