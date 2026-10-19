import Foundation

public struct WorkLayout: Sendable {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("download/bilibili-downloader", isDirectory: true)
    }

    public let root: URL
    public var cache: URL { root.appendingPathComponent("00_cache", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("01_log", isDirectory: true) }

    public init(directory: String) {
        root = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    public func cacheDirectory(for entry: VideoEntry) -> URL {
        cache.appendingPathComponent(sanitizeFileName(entry.id.replacingOccurrences(of: "#", with: "_")), isDirectory: true)
    }

    public func outputName(for entry: VideoEntry) -> String {
        // 成片统一放根目录，将合集/多P名称保留在文件名中，避免不同列表的 P01 重名。
        sanitizeFileName([entry.folder, entry.fileName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " - "))
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    }
}
