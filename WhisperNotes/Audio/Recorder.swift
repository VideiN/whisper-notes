import AVFoundation

/// 녹음 (PLAN.md §3.2). AVAudioEngine 입력을 받아
/// - 2분짜리 m4a 조각(audio/seg_NNNN.m4a)으로 저장하고 닫는다. m4a는 닫기 전에 앱이 죽으면 읽을 수 없으므로, 잃는 것은 마지막 조각 하나다
/// - 조각마다 벽시계 시작·끝 시각을 audio/manifest.json에 적는다
/// - 16kHz 모노로 바꿔 쉬는 곳에서 끊은 음성 조각을 onChunk로 넘긴다 (준실시간 전사)
/// 전화·Siri 같은 중단이나 입력 장치 변경이 있으면 지금 조각을 닫고, 다시 시작할 때 새 조각을 연다.
/// start/stop은 메인 스레드에서 부르고, 녹음 상태는 queue에서만 바꾼다
nonisolated final class Recorder: @unchecked Sendable {
    enum Event: Sendable {
        /// 입력 크기(0~1)와 지금까지 녹음한 길이(초)
        case progress(level: Float, seconds: Double)
        case interrupted
        case resumed
        case failed(String)
    }

    enum RecorderError: LocalizedError {
        case noInput

        var errorDescription: String? { "마이크 입력을 찾을 수 없습니다." }
    }

    static let segmentSeconds: Double = 120

    let session: SessionFiles
    private let mode: AVAudioSession.Mode
    private let onChunk: @Sendable (SpeechChunk) -> Void
    private let onEvent: @Sendable (Event) -> Void

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "io.github.videin.whispernotes.recorder", qos: .userInitiated)
    private let whisperFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var observers: [any NSObjectProtocol] = []

    // queue에서만 쓴다
    private var manifest = AudioManifest(segments: [])
    private var file: AVAudioFile?
    private var fileFrames: AVAudioFramePosition = 0
    private var converter: AVAudioConverter?
    private var chunker = SpeechChunker()
    private var meterPeak: Float = 0
    private var meterWrites = 0

    init(
        session: SessionFiles,
        mode: AVAudioSession.Mode,
        onChunk: @escaping @Sendable (SpeechChunk) -> Void,
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        self.session = session
        self.mode = mode
        self.onChunk = onChunk
        self.onEvent = onEvent
    }

    func start() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: mode)
        try audioSession.setActive(true)
        log("recorder: start \(session.id) (mode \(mode.rawValue))")
        try startEngine()
        observe()
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        queue.sync { endStream() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        log("recorder: stop \(session.id)")
    }

    private func startEngine() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }
        log("recorder: input \(format.sampleRate)Hz \(format.channelCount)ch")
        try queue.sync { try beginStream(sampleRate: format.sampleRate) }
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { @Sendable [weak self] buffer, _ in
            guard let self, let channels = buffer.floatChannelData else { return }
            // 첫 채널만 쓴다 (모노로 저장)
            let samples = Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
            self.queue.async { self.write(samples) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            queue.sync { endStream() }
            throw error
        }
    }

    private func restart(reason: String) {
        log("recorder: restart (\(reason))")
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        queue.sync { endStream() }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try startEngine()
            onEvent(.resumed)
        } catch {
            log("recorder: cannot restart: \(error)")
            onEvent(.failed(error.localizedDescription))
        }
    }

    private func observe() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { @Sendable [weak self] note in
                guard let self,
                      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    log("recorder: interrupted")
                    self.engine.stop()
                    self.queue.sync { self.endStream() }
                    self.onEvent(.interrupted)
                case .ended:
                    self.restart(reason: "interruption ended")
                @unknown default:
                    break
                }
            },
            // 입력 장치가 바뀌면(블루투스 마이크 연결·해제 등) 엔진이 멈춘다
            center.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { @Sendable [weak self] _ in
                self?.restart(reason: "audio configuration changed")
            },
        ]
    }

    // MARK: - queue에서만

    private func beginStream(sampleRate: Double) throws {
        chunker = SpeechChunker(origin: manifest.duration)
        try openSegment(sampleRate: sampleRate)
        if let file {
            converter = AVAudioConverter(from: file.processingFormat, to: whisperFormat)
        }
    }

    private func endStream() {
        closeSegment()
        if let chunk = chunker.flush() {
            onChunk(chunk)
        }
        converter = nil
    }

    private func openSegment(sampleRate: Double) throws {
        let name = String(format: "seg_%04d.m4a", manifest.segments.count + 1)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        file = try AVAudioFile(
            forWriting: session.audioDirectory.appending(path: name),
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        fileFrames = 0
        manifest.segments.append(.init(file: name, sampleRate: sampleRate, startedAt: .now, offset: manifest.duration))
        saveManifest()
    }

    private func closeSegment() {
        guard let file else { return }
        file.close()
        self.file = nil
        let index = manifest.segments.count - 1
        manifest.segments[index].endedAt = .now
        manifest.segments[index].duration = Double(fileFrames) / file.processingFormat.sampleRate
        saveManifest()
    }

    private func saveManifest() {
        do {
            try session.save(manifest, to: session.manifestURL)
        } catch {
            log("recorder: cannot save manifest: \(error)")
        }
    }

    private func write(_ samples: [Float]) {
        guard let file, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        do {
            try file.write(from: buffer)
        } catch {
            log("recorder: write failed: \(error)")
            return
        }
        fileFrames += AVAudioFramePosition(samples.count)
        let sampleRate = file.processingFormat.sampleRate

        meterPeak = max(meterPeak, samples.reduce(0) { max($0, abs($1)) })
        meterWrites += 1
        if meterWrites >= 3 {
            onEvent(.progress(level: min(meterPeak, 1), seconds: manifest.duration + Double(fileFrames) / sampleRate))
            meterPeak = 0
            meterWrites = 0
        }

        for chunk in chunker.append(resample(buffer)) {
            onChunk(chunk)
        }

        if Double(fileFrames) >= Self.segmentSeconds * sampleRate {
            closeSegment()
            do {
                try openSegment(sampleRate: sampleRate)
            } catch {
                log("recorder: cannot open next segment: \(error)")
                onEvent(.failed(error.localizedDescription))
            }
        }
    }

    /// 변환기를 녹음 내내 이어 써서 버퍼 경계에 잡음이 생기지 않게 한다
    private func resample(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let converter else { return [] }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * whisperFormat.sampleRate / buffer.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: whisperFormat, frameCapacity: capacity) else { return [] }
        nonisolated(unsafe) let input = buffer
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            log("recorder: resample failed: \(error?.localizedDescription ?? "?")")
            return []
        }
        guard let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
