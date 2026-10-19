import Foundation
import os

/// 日志写到工作目录的 01_log/yyyy-MM-dd.log，同时进系统日志。
/// 只记录排查和优化需要的信息，不记录 Cookie。
public final class Log: @unchecked Sendable {
    public enum Level: String { case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR" }

    public static let shared = Log()

    public static var directory: URL {
        shared.queue.sync { shared.logDirectory }
    }

    public static func configure(workDirectory: URL) { shared.configureDirectory(workDirectory: workDirectory) }

    /// 命令行 --verbose 时把日志同时打到终端
    public var echo: (@Sendable (String) -> Void)?

    private let queue = DispatchQueue(label: "bilidl.log")
    private var handle: FileHandle?
    private var day = ""
    private var logDirectory: URL
    private let os = Logger(subsystem: "local.bilidownloader", category: "app")
    private let dayFormat: DateFormatter
    private let timeFormat: DateFormatter

    init(workDirectory: URL = WorkLayout.defaultDirectory) {
        logDirectory = workDirectory.appendingPathComponent("01_log", isDirectory: true)
        dayFormat = DateFormatter()
        dayFormat.dateFormat = "yyyy-MM-dd"
        timeFormat = DateFormatter()
        timeFormat.dateFormat = "HH:mm:ss.SSS"
        queue.async { self.cleanup(in: self.logDirectory) }
    }

    func configureDirectory(workDirectory: URL) {
        let directory = workDirectory.appendingPathComponent("01_log", isDirectory: true)
        queue.sync {
            guard directory != logDirectory else { return }
            try? handle?.close()
            handle = nil
            day = ""
            logDirectory = directory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            cleanup(in: directory)
        }
    }

    public var currentFile: URL {
        queue.sync { logDirectory.appendingPathComponent(dayFormat.string(from: Date()) + ".log") }
    }

    public func write(_ level: Level, _ message: String, tag: String? = nil) {
        let now = Date()
        let line = "\(timeFormat.string(from: now)) [\(level.rawValue)]\(tag.map { " [\($0)]" } ?? "") \(message)"
        switch level {
        case .debug: os.debug("\(line, privacy: .public)")
        case .info: os.info("\(line, privacy: .public)")
        case .warn: os.warning("\(line, privacy: .public)")
        case .error: os.error("\(line, privacy: .public)")
        }
        echo?(line)
        queue.async {
            let d = self.dayFormat.string(from: now)
            if d != self.day || self.handle == nil {
                try? self.handle?.close()
                try? FileManager.default.createDirectory(at: self.logDirectory, withIntermediateDirectories: true)
                let url = self.logDirectory.appendingPathComponent(d + ".log")
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                self.handle = try? FileHandle(forWritingTo: url)
                _ = try? self.handle?.seekToEnd()
                self.day = d
            }
            try? self.handle?.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    /// 等待所有日志落盘（命令行退出前调用）
    public func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    /// 只保留最近 14 天
    private func cleanup(in directory: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        for f in files where f.pathExtension == "log" {
            if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d < cutoff {
                try? fm.removeItem(at: f)
            }
        }
    }

    public static func debug(_ m: String, tag: String? = nil) { shared.write(.debug, m, tag: tag) }
    public static func info(_ m: String, tag: String? = nil) { shared.write(.info, m, tag: tag) }
    public static func warn(_ m: String, tag: String? = nil) { shared.write(.warn, m, tag: tag) }
    public static func error(_ m: String, tag: String? = nil) { shared.write(.error, m, tag: tag) }

    /// 启动时记录环境，方便对比不同机器的性能
    public static func environment(ffmpeg: FFmpeg?, settings: AppSettings, app: String) {
        let p = ProcessInfo.processInfo
        var cpu = ""
        var size = 256
        var buf = [CChar](repeating: 0, count: size)
        if sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0) == 0 {
            cpu = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        info("==== \(app) 启动 · macOS \(p.operatingSystemVersionString) · \(cpu) · \(p.activeProcessorCount) 核 · 内存 \(p.physicalMemory / 1_073_741_824) GB")
        info("ffmpeg: \(ffmpeg.map { "\($0.path) (\($0.version))" } ?? "未找到")")
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(settings) { info("设置: \(String(decoding: data, as: UTF8.self))") }
    }
}

/// 计时工具
public struct Stopwatch: Sendable {
    public let start = Date()
    public init() {}
    public var elapsed: Double { Date().timeIntervalSince(start) }
    public var text: String { formatDuration(elapsed) }
}

public func formatDuration(_ s: Double) -> String {
    if s < 1 { return String(format: "%.0fms", s * 1000) }
    if s < 60 { return String(format: "%.1fs", s) }
    if s < 3600 { return String(format: "%dm%02ds", Int(s) / 60, Int(s) % 60) }
    return String(format: "%dh%02dm", Int(s) / 3600, Int(s) / 60 % 60)
}

public func formatBytes(_ b: Double) -> String {
    let units = ["B", "KB", "MB", "GB"]
    var v = b, i = 0
    while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    return String(format: i == 0 ? "%.0f %@" : "%.1f %@", v, units[i])
}
