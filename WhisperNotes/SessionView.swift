import os
import SwiftUI

/// 강의 1개: 녹음 중이면 녹음 상태와 준실시간 전사, 끝났으면 완료 후 전사.
/// PLAN.md에서는 필기 화면의 접이식 패널이지만, 필기(M1) 전이라 전사가 화면 전체다
struct SessionView: View {
    enum Tab: Hashable {
        case live
        case final
    }

    @Environment(AppModel.self) private var app
    let session: SessionFiles
    @State private var tab = Tab.live
    @State private var savedLive: [TranscriptSegment] = []
    @State private var savedFinal: [TranscriptSegment]?
    @State private var partialFinal: [TranscriptSegment] = []

    private var recording: RecordingController? {
        app.recording?.session == session ? app.recording : nil
    }

    private var live: LiveTranscriber? { app.live(for: session) }

    private var liveSegments: [TranscriptSegment] { live?.segments ?? savedLive }

    private var finalSegments: [TranscriptSegment] { savedFinal ?? partialFinal }

    private var title: String { app.summary(of: session)?.title ?? session.id }

    var body: some View {
        VStack(spacing: 0) {
            if let recording {
                RecordingBar(recording: recording) {
                    app.stopRecording()
                }
            } else {
                FinalBar(session: session, hasFinal: savedFinal != nil)
            }

            Picker("전사", selection: $tab) {
                Text("준실시간").tag(Tab.live)
                Text(savedFinal == nil ? "완료 후" : "완료 후 ✓").tag(Tab.final)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch tab {
            case .live:
                TranscriptList(segments: liveSegments, follow: recording != nil, empty: liveEmptyText)
            case .final:
                TranscriptList(segments: finalSegments, follow: false, empty: "녹음을 마친 뒤 \"완료 후 전사\"를 시작하면 전체를 다시 전사합니다.")
            }

            Divider()
            DebugStrip(live: live)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem {
                ShareLink(item: Transcript.text(title: "위스퍼 필기 · \(title)", segments: tab == .final ? finalSegments : liveSegments))
            }
        }
        .task(id: app.finalTranscriber.revision) {
            reload()
            if savedFinal != nil, recording == nil {
                tab = .final
            }
        }
    }

    private var liveEmptyText: String {
        if let message = live?.message { return message }
        if recording != nil { return "말소리가 쉬는 곳마다(최대 30초) 전사해서 여기에 붙입니다." }
        return "준실시간 전사가 없습니다."
    }

    private func reload() {
        savedLive = session.load(Transcript.self, from: session.liveURL)?.segments ?? []
        savedFinal = session.load(Transcript.self, from: session.finalURL)?.segments
        partialFinal = session.load(FinalProgress.self, from: session.progressURL)?.segments ?? []
        app.reload()
    }
}

private struct RecordingBar: View {
    let recording: RecordingController
    let stop: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse)
                Text(formatClock(recording.seconds))
                    .font(.title2.monospacedDigit())
                ProgressView(value: Double(recording.level))
                    .frame(maxWidth: 200)
                Spacer()
                Button("녹음 끝내기", systemImage: "stop.fill", role: .destructive, action: stop)
                    .buttonStyle(.borderedProminent)
            }
            if let status = recording.status {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .background(.bar)
    }
}

private struct FinalBar: View {
    @Environment(AppModel.self) private var app
    let session: SessionFiles
    let hasFinal: Bool

    private var transcriber: FinalTranscriber { app.finalTranscriber }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let job = transcriber.job, job.session == session {
                HStack {
                    Text("완료 후 전사 · \(job.model.title) · \(job.compute.title)")
                        .font(.headline)
                    Spacer()
                    Button("멈추기", systemImage: "pause.fill", action: transcriber.cancel)
                        .buttonStyle(.bordered)
                }
                ProgressView(value: job.fraction)
                HStack {
                    Text("\(job.status) · \(formatClock(job.doneSeconds)) / \(formatClock(job.totalSeconds))")
                    Spacer()
                    if let speed = job.speed {
                        Text(String(format: "%.1f배속", speed))
                    }
                    if job.inBackgroundTask {
                        Label(job.backgroundGPU ? "백그라운드 GPU" : "백그라운드 이어 가기", systemImage: "moon")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else if transcriber.pausedSession == session {
                Text("앱으로 돌아오면 완료 후 전사를 이어 갑니다.")
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Button(startTitle, systemImage: "text.badge.checkmark") {
                        transcriber.start(session)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!app.isIdle)
                    Spacer()
                    Text("\(AppSettings.finalModel.title) · \(AppSettings.computeMode.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("충전기에 꽂고 화면을 켜 둔 채로 두는 것이 가장 빠릅니다. 앱을 나가도 시스템이 허락하면 이어 갑니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = transcriber.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(.bar)
    }

    private var startTitle: String {
        if FileManager.default.fileExists(atPath: session.progressURL.path) { return "완료 후 전사 이어 하기" }
        return hasFinal ? "완료 후 전사 다시 하기" : "완료 후 전사 시작"
    }
}

private struct TranscriptList: View {
    let segments: [TranscriptSegment]
    let follow: Bool
    let empty: String

    var body: some View {
        if segments.isEmpty {
            ContentUnavailableView(empty, systemImage: "text.bubble")
                .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(segments.indices, id: \.self) { index in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(formatClock(segments[index].start))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .trailing)
                            Text(segments[index].text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(follow ? .bottom : .top)
        }
    }
}

/// 실기기 시험용 상태 줄 (PLAN.md §6 디버그 오버레이): 계산 장치, 발열, 남은 메모리, 전사 대기·속도
private struct DebugStrip: View {
    @Environment(AppModel.self) private var app
    let live: LiveTranscriber?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            HStack(spacing: 16) {
                Text(app.models.loadedDescription ?? "모델 안 불러옴")
                Text("발열 \(thermalText)")
                Text("남은 메모리 \(String(format: "%.1f", Double(os_proc_available_memory()) / 1_073_741_824))GB")
                if let live {
                    Text("대기 \(live.pendingCount)\(live.isTranscribing ? "+1" : "")")
                    if let speed = live.lastSpeed {
                        Text(String(format: "%.1f배속", speed))
                    }
                    if live.skippedChunks > 0 {
                        Text("건너뜀 \(live.skippedChunks)")
                    }
                    if live.isPaused {
                        Text("일시정지 (백그라운드)")
                    }
                }
                Spacer()
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    private var thermalText: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "정상"
        case .fair: "약간 높음"
        case .serious: "높음"
        case .critical: "매우 높음"
        @unknown default: "?"
        }
    }
}
