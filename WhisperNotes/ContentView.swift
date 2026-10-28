import SwiftUI

/// M0 빈 앱 (PLAN.md §8): 설치한 빌드를 확인하고 기록을 보는 화면만 있다
struct ContentView: View {
    private let build = BuildInfo.current

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("PDF 필기와 강의 전사 앱을 만드는 중입니다.")
                }
                Section("앱 정보") {
                    LabeledContent("빌드", value: "\(build.summary) · \(build.version)")
                    NavigationLink("기록") {
                        LogView()
                    }
                }
            }
            .navigationTitle("위스퍼 필기")
        }
    }
}
