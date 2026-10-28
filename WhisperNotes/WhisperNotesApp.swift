import SwiftUI

@main
struct WhisperNotesApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        log("build: \(BuildInfo.current.summary) (version \(BuildInfo.current.version))")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            log("app: \(phase)")
        }
    }
}
