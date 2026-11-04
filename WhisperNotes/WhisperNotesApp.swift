import os
import SwiftUI

@main
struct WhisperNotesApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var app = AppModel()

    init() {
        log("build: \(BuildInfo.current.summary) (version \(BuildInfo.current.version))")
        // 메모리 한도 엔타이틀먼트가 들어갔는지 실기기에서 보려고 남긴다 (TestFlight 빌드에만 들어간다)
        let gb = { (bytes: UInt64) in String(format: "%.1f", Double(bytes) / 1_073_741_824) }
        log("memory: 앱이 쓸 수 있는 메모리 \(gb(UInt64(os_proc_available_memory())))GB, 기기 \(gb(ProcessInfo.processInfo.physicalMemory))GB")
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
