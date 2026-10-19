import Foundation

/// 本程序的分享预设，不代表微信官方压缩标准。
public struct WechatShareOptions: Sendable, Equatable {
    public let speed: Double
    public let videoKbps: Int
    public let maxDimension: Int
    public static let audioKbps = 64

    public init(speed: Double = 1.5, videoKbps: Int = 1000, maxDimension: Int = 960) {
        self.speed = speed.isFinite ? (min(2, max(1, speed)) * 100).rounded() / 100 : 1.5
        self.videoKbps = min(2000, max(400, videoKbps))
        self.maxDimension = min(1280, max(320, maxDimension)) / 2 * 2
    }

    public var speedLabel: String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), speed)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    public func outputURL(for input: URL) -> URL {
        let suffix = " (微信分享 \(speedLabel)倍 \(maxDimension)px \(videoKbps)k)"
        var base = sanitizeFileName(input.deletingPathExtension().lastPathComponent)
        while base.utf8.count + suffix.utf8.count > 200 { base.removeLast() }
        return input.deletingLastPathComponent()
            .appendingPathComponent(base + suffix + ".mp4")
    }

    var videoFilter: String {
        // 方形边界同时适配横竖屏；不放大低分辨率源，H.264 输出尺寸保持偶数。
        "scale=w='min(iw,\(maxDimension))':h='min(ih,\(maxDimension))':force_original_aspect_ratio=decrease:force_divisible_by=2,"
        + "setpts=(PTS-STARTPTS)/\(speed),fps=30,format=yuv420p"
    }
}

public extension FFmpeg {
    /// 两遍编码使体积接近目标码率；先绘制字幕，再同步加速画面与声音。
    func exportWechatShare(input: URL, output: URL, options: WechatShareOptions,
                           ass: URL? = nil, sourceDuration: Double? = nil, tag: String? = nil,
                           progress: @escaping @Sendable (FFProgress) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        let fm = FileManager.default
        let work = output.deletingLastPathComponent().appendingPathComponent(".wechat-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        var filter = options.videoFilter
        if let ass {
            try fm.copyItem(at: ass, to: work.appendingPathComponent("danmaku.ass"))
            filter = "ass=danmaku.ass," + filter
        }
        let duration = sourceDuration.map { $0 / options.speed }
        let common = ["-i", input.path, "-map", "0:v:0", "-vf", filter,
                      "-c:v", "libx264", "-preset", "medium", "-b:v", "\(options.videoKbps)k",
                      "-maxrate", "\(options.videoKbps * 2)k", "-bufsize", "\(options.videoKbps * 4)k",
                      "-pix_fmt", "yuv420p", "-passlogfile", work.appendingPathComponent("pass").path]
        Log.info("微信分享：\(options.speedLabel)倍，最长边 \(options.maxDimension)px，30fps，H.264 \(options.videoKbps)kbps / AAC 64kbps", tag: tag)
        try await run(common + ["-pass", "1", "-an", "-f", "null", "/dev/null"], cwd: work, duration: duration, tag: tag) { p in
            progress(FFProgress(fraction: p.fraction * 0.5, speed: p.speed, fps: p.fps, outTime: p.outTime))
        }
        try Task.checkCancellation()
        let partial = work.appendingPathComponent("share.mp4")
        try await run(common + ["-pass", "2", "-map", "0:a:0?", "-af", "asetpts=PTS-STARTPTS,atempo=\(options.speed)",
                               "-c:a", "aac", "-b:a", "64k", "-ac", "2", "-ar", "44100",
                               "-map_metadata", "-1", "-map_chapters", "-1", "-movflags", "+faststart", partial.path],
                      cwd: work, duration: duration, tag: tag) { p in
            progress(FFProgress(fraction: 0.5 + p.fraction * 0.5, speed: p.speed, fps: p.fps, outTime: p.outTime))
        }
        try Task.checkCancellation()
        try fm.moveItem(at: partial, to: output)
        Log.info("微信分享完成：\(formatBytes(Double(fileSize(output)))) → \(output.lastPathComponent)", tag: tag)
    }

    func probeDuration(_ input: URL) async -> Double? {
        let probe = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("ffprobe")
        let process = Process()
        process.executableURL = probe
        process.arguments = ["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", input.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let value = Double(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, value > 0 else { return nil }
        return value
    }
}
