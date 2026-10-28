import SwiftUI

@main
struct WhisperNotesApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var app = AppModel()

    init() {
        log("build: \(BuildInfo.current.summary) (version \(BuildInfo.current.version))")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(app)
        }
        .onChange(of: scenePhase) { _, phase in
            log("app: \(phase)")
            app.scenePhaseChanged(phase)
        }
    }
}
