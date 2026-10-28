import Foundation

/// 강의 회차(세션) 1개의 파일들 (PLAN.md §7의 sessions/<id>/).
/// 필기(M1)보다 녹음·전사를 먼저 만들어서, 지금은 노트 없이 Documents/sessions/ 아래에 둔다.
/// Documents는 Files 앱에 보이므로 녹음과 전사본을 꺼낼 수 있다 (CER 시험용)
nonisolated struct SessionFiles: Hashable, Identifiable, Sendable {
    /// 폴더 이름. 만든 시각이라 이름순이 시간순이다 (예: 20261029-153012)
    let id: String
    let directory: URL

    static var root: URL {
        URL.documentsDirectory.appending(path: "sessions", directoryHint: .isDirectory)
    }

    var audioDirectory: URL { directory.appending(path: "audio", directoryHint: .isDirectory) }
    var manifestURL: URL { audioDirectory.appending(path: "manifest.json") }
    var transcriptDirectory: URL { directory.appending(path: "transcript", directoryHint: .isDirectory) }
    var liveURL: URL { transcriptDirectory.appending(path: "live.json") }
    var finalURL: URL { transcriptDirectory.appending(path: "final.json") }
    var progressURL: URL { transcriptDirectory.appending(path: "progress.json") }
    var metaURL: URL { directory.appending(path: "meta.json") }

    static func create(now: Date = .now) throws -> SessionFiles {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let id = formatter.string(from: now)
        let session = SessionFiles(id: id, directory: root.appending(path: id, directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: session.audioDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: session.transcriptDirectory, withIntermediateDirectories: true)
        try session.save(SessionMeta(createdAt: now), to: session.metaURL)
        return session
    }

    /// 최근 것부터
    static func all() -> [SessionFiles] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: "meta.json").path) }
            .map { SessionFiles(id: $0.lastPathComponent, directory: $0) }
            .sorted { $0.id > $1.id }
    }

    func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSON.decoder().decode(type, from: data)
        } catch {
            log("session: cannot read \(id)/\(url.lastPathComponent): \(error)")
            return nil
        }
    }

    func save<T: Encodable>(_ value: T, to url: URL) throws {
        try JSON.encoder().encode(value).write(to: url, options: .atomic)
    }

    func delete() throws {
        try FileManager.default.removeItem(at: directory)
    }
}

nonisolated enum JSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
