import SwiftUI

@main
struct DictationApp: App {
    @StateObject private var engine = DictationEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                // The keyboard opens dictation://start when the app isn't armed yet.
                .onOpenURL { url in
                    guard url.scheme == Shared.urlScheme, url.host == "start" else { return }
                    engine.arm()
                }
        }
    }
}
