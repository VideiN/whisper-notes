import SwiftUI

/// 첫 화면: 강의 녹음 목록, 전사 모델, 설정, 앱 정보.
/// 필기(M1)보다 녹음·전사(M2·M3)를 먼저 만들고 있어서 PDF 없이 녹음만 한다
struct ContentView: View {
    @Environment(AppModel.self) private var app
    @State private var path: [SessionFiles] = []
    private let build = BuildInfo.current

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    if let recording = app.recording {
                        NavigationLink(value: recording.session) {
                            Label("녹음 중 · \(formatClock(recording.seconds))", systemImage: "waveform")
                                .foregroundStyle(.red)
                        }
                    } else {
                        Button("새 강의 녹음", systemImage: "record.circle") {
                            Task {
                                if let session = await app.startRecording() {
                                    path.append(session)
                                }
                            }
                        }
                        .disabled(!app.isIdle)
                    }
                }

                Section("강의") {
                    if app.sessions.isEmpty {
                        Text("녹음한 강의가 없습니다.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(app.sessions) { summary in
                        NavigationLink(value: summary.session) {
                            SessionRow(summary: summary)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            app.delete(app.sessions[index].session)
                        }
                    }
                }

                ModelSection()
                SettingsSection()

                Section("앱 정보") {
                    LabeledContent("빌드", value: "\(build.summary) · \(build.version)")
                    NavigationLink("기록") {
                        LogView()
                    }
                }
            }
            .navigationTitle("위스퍼 필기")
            .navigationDestination(for: SessionFiles.self) { session in
                SessionView(session: session)
            }
            .alert("오류", isPresented: Binding { app.errorMessage != nil } set: { if !$0 { app.errorMessage = nil } }) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(app.errorMessage ?? "")
            }
        }
    }
}

private struct SessionRow: View {
    let summary: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary.title)
            HStack(spacing: 8) {
                Text(formatClock(summary.duration))
                if let model = summary.finalModel {
                    Label("완료 후 전사 (\(model.title))", systemImage: "checkmark.seal")
                } else if summary.hasProgress {
                    Label("완료 후 전사 중단됨", systemImage: "pause.circle")
                } else if summary.liveSegments > 0 {
                    Label("준실시간 전사", systemImage: "text.bubble")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct ModelSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Section {
            ForEach(WhisperModel.allCases, id: \.self) { model in
                ModelRow(model: model, models: app.models)
            }
        } header: {
            Text("전사 모델")
        } footer: {
            Text("처음 한 번 받아 기기에 둡니다 (Wi-Fi 권장). 준실시간 전사는 large-v3 Turbo를 씁니다. 처음 불러올 때는 기기에 맞게 최적화하느라 몇 분 걸릴 수 있습니다.")
        }
    }
}

private struct ModelRow: View {
    let model: WhisperModel
    let models: ModelManager

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                Text(models.downloaded.contains(model) ? "받음" : model.approximateSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if case .failed(let message) = models.phase(model) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            switch models.phase(model) {
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .frame(width: 120)
                Text("\(Int(fraction * 100))%")
                    .font(.caption.monospacedDigit())
            case .loading:
                ProgressView()
                Text("불러오는 중")
                    .font(.caption)
            case .idle, .failed:
                if models.downloaded.contains(model) {
                    Button("지우기", role: .destructive) {
                        Task { await models.delete(model) }
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button("받기") {
                        Task { await models.download(model) }
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}

private struct SettingsSection: View {
    @AppStorage(AppSettings.Key.computeMode) private var computeMode = ComputeMode.gpu
    @AppStorage(AppSettings.Key.finalModel) private var finalModel = WhisperModel.turbo
    @AppStorage(AppSettings.Key.liveEnabled) private var liveEnabled = true
    @AppStorage(AppSettings.Key.audioMode) private var audioMode = AudioMode.standard

    var body: some View {
        Section {
            Picker("계산 장치", selection: $computeMode) {
                ForEach(ComputeMode.allCases, id: \.self) { mode in
                    Text(mode.title)
                }
            }
            Picker("완료 후 전사 모델", selection: $finalModel) {
                ForEach(WhisperModel.allCases, id: \.self) { model in
                    Text(model.title)
                }
            }
            Toggle("녹음하면서 전사 (준실시간)", isOn: $liveEnabled)
            Picker("마이크 모드", selection: $audioMode) {
                ForEach(AudioMode.allCases, id: \.self) { mode in
                    Text(mode.title)
                }
            }
        } header: {
            Text("전사 설정")
        } footer: {
            Text("GPU로 먼저 시험하고, 기기가 뜨거워지거나 필기가 늦어지면 뉴럴 엔진으로 바꿉니다. 바꾸면 다음 녹음·전사부터 모델을 다시 불러옵니다.")
        }
    }
}
