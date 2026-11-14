import SwiftUI
import Sparkle

// Placeholder app shell: an empty window plus the Sparkle updater, so the build, signing and release
// pipeline can be verified end to end. The UI replaces this file.
@main
struct MacAuthApp: App {
    private let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    init() {
        // Without a public EdDSA key there is nothing to verify updates against: checking stays off.
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        if !(key ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            updater.startUpdater()
        }
    }

    var body: some Scene {
        WindowGroup {
            Text("MacAuth")
                .font(.largeTitle)
                .frame(minWidth: 760, minHeight: 520)
        }
    }
}
