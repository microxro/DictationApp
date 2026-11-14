import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var engine: DictationEngine
    @State private var scratch = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                orb
                armButton
                banners
                modelRow
                lastResult
                tryItField
                setupGuide
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .animation(.smooth, value: engine.state)
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: 4) {
            Text("Dictation").font(.largeTitle.bold())
            Text("On-device. Private. Free.").foregroundStyle(.secondary)
        }
    }

    /// "Ready" must not be shown while the speech model is still loading or has failed.
    private var orbTitle: String {
        if engine.state == .armed {
            switch engine.modelStatus {
            case .loading: return "Loading model…"
            case .failed: return "Model error"
            default: break
            }
        }
        return engine.state.title
    }

    private var orb: some View {
        let color = engine.state.color
        return ZStack {
            Circle().fill(color.opacity(0.15)).frame(width: 190, height: 190)
            Circle().fill(color.gradient).frame(width: 120, height: 120)
                .shadow(color: color.opacity(0.5), radius: 18)
            Image(systemName: engine.state.symbol)
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, isActive: engine.state == .recording || engine.state == .processing)
        }
        .overlay(alignment: .bottom) {
            Text(orbTitle).font(.headline).foregroundStyle(color).offset(y: 34)
        }
        .padding(.bottom, 30)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(orbTitle)")
    }

    private var armButton: some View {
        Button {
            engine.toggleArmed()
        } label: {
            Label(engine.state == .off ? "Arm microphone" : "Disarm microphone",
                  systemImage: engine.state == .off ? "mic.badge.plus" : "mic.slash")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(engine.state == .off ? .accentColor : .gray)
    }

    @ViewBuilder private var banners: some View {
        if let error = engine.errorMessage {
            Banner(text: error, systemImage: "exclamationmark.triangle.fill", color: .red)
        }
        if let notice = engine.notice {
            Banner(text: notice, systemImage: "info.circle.fill", color: .orange)
        }
    }

    private var modelRow: some View {
        HStack {
            switch engine.modelStatus {
            case .notLoaded:
                Label("Speech model: not loaded (loads when armed)", systemImage: "circle.dashed").foregroundStyle(.secondary)
            case .loading:
                ProgressView().padding(.trailing, 6)
                Text("Loading speech model… (first run downloads ~600 MB)")
            case .ready:
                Label("Speech model ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Label("Speech model failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Spacer()
                Button("Retry") { engine.retryModel() }.buttonStyle(.bordered)
            }
            Spacer(minLength: 0)
        }
        .font(.subheadline)
    }

    private var lastResult: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last dictation").font(.headline)
                Spacer()
                if !engine.lastText.isEmpty {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = engine.lastText }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            Text(engine.lastText.isEmpty ? "Nothing yet." : engine.lastText)
                .foregroundStyle(engine.lastText.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var tryItField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try it here").font(.headline)
            Text("Switch to the Dictation keyboard with the 🌐 key, then tap the mic.")
                .font(.subheadline).foregroundStyle(.secondary)
            TextField("Dictate into this field…", text: $scratch, axis: .vertical)
                .lineLimit(3...8)
                .padding(14)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var setupGuide: some View {
        DisclosureGroup("One-time setup") {
            VStack(alignment: .leading, spacing: 10) {
                Text("1. Settings → General → Keyboard → Keyboards → Add New Keyboard → Dictation.")
                Text("2. Tap Dictation in that list and turn on **Allow Full Access**. It's required to talk to this app. Nothing leaves your iPad.")
                Text("3. In any text field, hold 🌐 and choose Dictation. Tap the mic.")
                Text("4. If the app isn't armed, the first tap opens it. Swipe back, then tap the mic again.")
                Text("The orange mic dot stays on while armed. Disarm here, or wait \(DictationEngine.idleMinutes) idle minutes.")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct Banner: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

extension Shared.State {
    var title: String {
        switch self {
        case .off: return "Off"
        case .armed: return "Ready"
        case .recording: return "Listening…"
        case .processing: return "Writing…"
        }
    }

    var symbol: String {
        switch self {
        case .off: return "mic.slash"
        case .armed: return "mic"
        case .recording: return "waveform"
        case .processing: return "ellipsis"
        }
    }

    var color: Color {
        switch self {
        case .off: return .gray
        case .armed: return .green
        case .recording: return .red
        case .processing: return .purple
        }
    }
}
