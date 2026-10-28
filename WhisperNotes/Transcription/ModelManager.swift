import Foundation

/// 전사 모델 받기·불러오기 (PLAN.md §3.3, §7).
/// 모델은 Application Support/Models에 두고 백업에서 뺀다 (Caches는 시스템이 지워서 수 GB를 다시 받게 될 수 있다).
/// 메모리를 아끼려고 한 번에 모델 하나만 불러 둔다
@Observable
final class ModelManager {
    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case loading
        case failed(String)
    }

    enum ModelError: LocalizedError {
        case notDownloaded(WhisperModel)

        var errorDescription: String? {
            switch self {
            case .notDownloaded(let model): "\(model.title) 모델을 먼저 받아 주세요."
            }
        }
    }

    private struct Key: Equatable {
        let model: WhisperModel
        let compute: ComputeMode
    }

    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Models", directoryHint: .isDirectory)
    }

    private(set) var phases: [WhisperModel: Phase] = [:]
    private(set) var downloaded: Set<WhisperModel> = []
    /// 지금 불러 둔 모델 (디버그 표시용)
    private(set) var loadedDescription: String?

    private var engine: WhisperEngine?
    private var loading: Task<WhisperEngine, any Error>?
    private var loadingKey: Key?

    init() {
        downloaded = Set(WhisperModel.allCases.filter { folder(for: $0) != nil })
    }

    func phase(_ model: WhisperModel) -> Phase {
        phases[model] ?? .idle
    }

    func download(_ model: WhisperModel) async {
        guard phase(model) != .loading, !isDownloading(model) else { return }
        phases[model] = .downloading(0)
        log("model: download \(model.rawValue)")
        do {
            try prepareDirectory()
            let folder = try await WhisperEngine.download(model, to: Self.directory) { fraction in
                Task { @MainActor in
                    if case .downloading = self.phase(model) {
                        self.phases[model] = .downloading(fraction)
                    }
                }
            }
            // 받은 폴더를 Models 기준 상대 경로로 적어 둔다 (앱을 다시 설치하면 컨테이너 경로가 바뀐다)
            let relative = folder.path.replacingOccurrences(of: Self.directory.path + "/", with: "")
            try Data(relative.utf8).write(to: marker(for: model), options: .atomic)
            downloaded.insert(model)
            phases[model] = .idle
            log("model: downloaded \(model.rawValue) → \(relative)")
        } catch {
            log("model: download failed \(model.rawValue): \(error)")
            phases[model] = .failed(error.localizedDescription)
        }
    }

    func delete(_ model: WhisperModel) async {
        if engine?.model == model {
            await engine?.unload()
            engine = nil
            loadedDescription = nil
        }
        if let folder = folder(for: model) {
            try? FileManager.default.removeItem(at: folder)
        }
        try? FileManager.default.removeItem(at: marker(for: model))
        downloaded.remove(model)
        phases[model] = .idle
        log("model: deleted \(model.rawValue)")
    }

    /// 그 모델을 그 계산 장치로 불러 둔 엔진. 다른 것을 불러 두었으면 내리고 새로 불러온다
    func engine(_ model: WhisperModel, compute: ComputeMode) async throws -> WhisperEngine {
        let key = Key(model: model, compute: compute)
        while true {
            if let engine, engine.model == model, engine.compute == compute {
                return engine
            }
            guard let loading else { break }
            if loadingKey == key {
                return try await loading.value
            }
            _ = try? await loading.value
        }
        guard let folder = folder(for: model) else { throw ModelError.notDownloaded(model) }

        let previous = engine
        engine = nil
        loadedDescription = nil
        phases[model] = .loading
        let started = ContinuousClock.now
        let task = Task<WhisperEngine, any Error> {
            if let previous {
                await previous.unload()
            }
            return try await WhisperEngine.load(model, compute: compute, folder: folder, tokenizerFolder: Self.directory)
        }
        loading = task
        loadingKey = key
        defer {
            loading = nil
            loadingKey = nil
        }
        do {
            let loaded = try await task.value
            let seconds = (ContinuousClock.now - started) / .seconds(1)
            log("model: loaded \(model.rawValue) on \(compute.rawValue) in \(String(format: "%.1f", seconds))s")
            engine = loaded
            loadedDescription = "\(model.title) · \(compute.title)"
            phases[model] = .idle
            return loaded
        } catch {
            log("model: load failed \(model.rawValue) on \(compute.rawValue): \(error)")
            phases[model] = .failed(error.localizedDescription)
            throw error
        }
    }

    private func isDownloading(_ model: WhisperModel) -> Bool {
        if case .downloading = phase(model) { true } else { false }
    }

    private func marker(for model: WhisperModel) -> URL {
        Self.directory.appending(path: "\(model.rawValue).downloaded")
    }

    private func folder(for model: WhisperModel) -> URL? {
        guard let data = try? Data(contentsOf: marker(for: model)) else { return nil }
        let folder = Self.directory.appending(path: String(decoding: data, as: UTF8.self), directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }

    private func prepareDirectory() throws {
        var directory = Self.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }
}
