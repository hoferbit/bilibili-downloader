import Foundation

public struct WorkLayout: Sendable {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/bilibili-downloader", isDirectory: true)
    }

    public let root: URL
    public var cache: URL { root.appendingPathComponent("00_cache", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("01_log", isDirectory: true) }

    public init(directory: String) {
        root = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    public func cacheDirectory(for entry: VideoEntry, date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return cache.appendingPathComponent(sanitizeFileName(formatter.string(from: date) + " " + entry.title), isDirectory: true)
    }

    public func outputName(for entry: VideoEntry) -> String {
        sanitizeFileName(entry.title)
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    }
}
