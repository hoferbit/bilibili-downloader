import Foundation

public enum JobStage: String, Codable, Sendable {
    case waiting, resolving, downloading, merging, danmaku, rendering, retrying, finished, skipped, failed, cancelled

    public var isTerminal: Bool { [.finished, .skipped, .failed, .cancelled].contains(self) }
}

public struct JobUpdate: Sendable {
    public var stage: JobStage
    public var progress: Double?
    public var detail: String
    public var quality: String?
}

public struct JobResult: Sendable {
    public var file: URL
    public var skipped: Bool
    public var note: String
}

public func sanitizeFileName(_ name: String) -> String {
    let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
    var s = String(String.UnicodeScalarView(name.unicodeScalars.map { illegal.contains($0) ? "_" : $0 }))
    s = s.trimmingCharacters(in: .whitespaces)
    while s.hasPrefix(".") { s.removeFirst() }
    if s.isEmpty { s = "untitled" }
    // 文件名最多 255 字节，给后缀留余量
    while s.utf8.count > 200 { s.removeLast() }
    return s
}

public extension VideoEntry {
    /// 日志里区分任务用的短标签
    var logTag: String {
        if let ep = epid { return "ep\(ep)" }
        return (bvid.isEmpty ? "av\(aid)" : bvid) + "/\(cid)"
    }
}

/// 记录每个阶段耗时，任务结束时输出一行汇总
private final class StageTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [(String, Double)] = []
    private var current: (String, Date)?
    let total = Stopwatch()

    func begin(_ name: String) {
        lock.withLock {
            if let (n, d) = current { stages.append((n, Date().timeIntervalSince(d))) }
            current = (name, Date())
        }
    }

    var summary: String {
        lock.withLock {
            var all = stages
            if let (n, d) = current { all.append((n, Date().timeIntervalSince(d))) }
            return all.map { "\($0.0) \(formatDuration($0.1))" }.joined(separator: " / ")
        }
    }
}

public struct DownloadPipeline: Sendable {
    public let client: BiliClient
    public let settings: AppSettings
    public let ffmpeg: FFmpeg

    public init(client: BiliClient, settings: AppSettings, ffmpeg: FFmpeg) {
        self.client = client
        self.settings = settings
        self.ffmpeg = ffmpeg
    }

    public func run(_ e: VideoEntry, downloadStarted: @escaping @Sendable () -> Void = {}, update: @escaping @Sendable (JobUpdate) -> Void) async throws -> JobResult {
        let tag = e.logTag
        let timer = StageTimer()
        Log.info("开始任务「\(e.title)」 aid=\(e.aid) bvid=\(e.bvid) cid=\(e.cid)\(e.epid.map { " ep=\($0)" } ?? "")", tag: tag)
        let maxAttempts = max(1, settings.autoRetry + 1)
        var attempt = 1
        while true {
            do {
                let r = try await runStages(e, tag: tag, timer: timer, attempt: attempt, maxAttempts: maxAttempts, downloadStarted: downloadStarted, update: update)
                Log.info("任务\(r.skipped ? "跳过" : "完成")\(attempt > 1 ? "（第 \(attempt) 次尝试）" : "")，总用时 \(timer.total.text)：\(timer.summary)"
                    + (r.note.isEmpty ? "" : "；\(r.note)") + " → \(r.file.path)", tag: tag)
                return r
            } catch {
                if Task.isCancelled || error is CancellationError {
                    Log.info("任务已取消，已用 \(timer.total.text)：\(timer.summary)", tag: tag)
                    throw CancellationError()
                }
                guard isRetryable(error), attempt < maxAttempts else {
                    Log.error("任务失败（第 \(attempt)/\(maxAttempts) 次\(isRetryable(error) ? "" : "，不可重试的错误")，"
                        + "\(timer.total.text)：\(timer.summary)）：\(error.localizedDescription)", tag: tag)
                    throw error
                }
                // 退避等待；已完成的下载、合并、弹幕、渲染分段都会保留，下次直接复用
                let delay = [5, 15, 30, 60][min(attempt - 1, 3)]
                Log.warn("第 \(attempt)/\(maxAttempts) 次失败，\(delay) 秒后重试：\(error.localizedDescription)", tag: tag)
                timer.begin("等待重试")
                for remaining in stride(from: delay, to: 0, by: -1) {
                    update(JobUpdate(stage: .retrying, progress: nil,
                                     detail: "出错：\(error.localizedDescription) · \(remaining) 秒后第 \(attempt + 1)/\(maxAttempts) 次尝试"))
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                attempt += 1
            }
        }
    }

    private func runStages(_ e: VideoEntry, tag: String, timer: StageTimer, attempt: Int, maxAttempts: Int,
                           downloadStarted: @escaping @Sendable () -> Void,
                           update rawUpdate: @escaping @Sendable (JobUpdate) -> Void) async throws -> JobResult {
        rawUpdate(JobUpdate(stage: .resolving, progress: nil, detail: "等待下载通道…"))
        let lease = try await PipelineSchedule.shared.begin()
        downloadStarted()
        do {
            let result = try await runScheduledStages(e, tag: tag, timer: timer, attempt: attempt,
                                                       maxAttempts: maxAttempts, lease: lease, update: rawUpdate)
            await lease.finish()
            return result
        } catch {
            await lease.finish()
            throw error
        }
    }

    private func runScheduledStages(_ e: VideoEntry, tag: String, timer: StageTimer, attempt: Int,
                                    maxAttempts: Int, lease: PipelineLease,
                                    update rawUpdate: @escaping @Sendable (JobUpdate) -> Void) async throws -> JobResult {
        // 重试时在状态前标注第几次
        let prefix = attempt == 1 ? "" : "[重试 \(attempt - 1)/\(maxAttempts - 1)] "
        let update: @Sendable (JobUpdate) -> Void = { (u: JobUpdate) in
            var u = u
            u.detail = prefix + u.detail
            rawUpdate(u)
        }
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: (settings.downloadDir as NSString).expandingTildeInPath, isDirectory: true)
        if let folder = e.folder { dir.appendPathComponent(sanitizeFileName(folder), isDirectory: true) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = sanitizeFileName(e.fileName)
        let final = dir.appendingPathComponent(name + ".mp4")
        let tmp = dir.appendingPathComponent(".bilidl-tmp", isDirectory: true)
            .appendingPathComponent(sanitizeFileName(e.id.replacingOccurrences(of: "#", with: "_")), isDirectory: true)
        if fm.fileExists(atPath: final.path) {
            if settings.wechatShareEnabled {
                let share = settings.wechatShareOptions.outputURL(for: final)
                if fm.fileExists(atPath: share.path) {
                    return JobResult(file: share, skipped: true, note: "微信分享文件已存在，跳过")
                }
                try await lease.compose()
                let duration = await ffmpeg.probeDuration(final)
                let result = try await makeWechatShare(final, duration: duration, tag: tag, update: update)
                try? fm.removeItem(at: tmp)
                return result
            }
            return JobResult(file: final, skipped: true, note: "文件已存在，跳过")
        }

        timer.begin("解析")
        update(JobUpdate(stage: .resolving, progress: nil, detail: "获取播放地址…"))
        let s = try await client.streams(for: e, quality: settings.quality, codec: settings.codec,
                                         prefer60: settings.prefer60, tag: tag)
        let quality = s.summary
        var notes: [String] = []
        if s.qn < settings.quality && !client.isLoggedIn && s.qn <= 32 {
            notes.append("未登录，最高只能 480P")
        }

        let sourceKey = tmp.appendingPathComponent("source.key")
        if fm.fileExists(atPath: tmp.path),
           (try? String(contentsOf: sourceKey, encoding: .utf8)) != s.cacheIdentity {
            Log.info("所选流已改变或缓存缺少指纹，清理旧缓存", tag: tag)
            try fm.removeItem(at: tmp)
        }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        try s.cacheIdentity.write(to: sourceKey, atomically: true, encoding: .utf8)

        // 1. 下载 + 合并。上次合并成功的文件会保留，重试时（比如渲染失败）直接复用
        let merged = tmp.appendingPathComponent("merged.mp4")
        var (w, h, fps) = (s.width, s.height, s.fps)
        if fm.fileExists(atPath: merged.path), let probed = await ffmpeg.probeSize(merged) {
            try await lease.compose()
            (w, h, fps) = probed
            Log.info("复用上次合并好的文件 \(formatBytes(Double(fileSize(merged))))（\(w)×\(h) \(String(format: "%.2f", fps))fps），跳过下载", tag: tag)
        } else {
            timer.begin("下载")
            try await download(s, into: tmp, merged: merged, quality: quality, tag: tag, timer: timer, lease: lease, update: update)
        }

        if s.needsDecodeValidation {
            update(JobUpdate(stage: .merging, progress: nil, detail: "验证视频可直接解码…", quality: quality))
            try await ffmpeg.run(["-xerror", "-i", merged.path, "-map", "0:v:0", "-frames:v", "1", "-an", "-f", "null", "-"], tag: tag)
            Log.info("接口总标记 is_drm=true，但所选普通视频流实际解码验证通过", tag: tag)
        }

        // 2. 弹幕
        var outputFile = merged
        var outQuality = quality
        if settings.danmakuMode != .none {
            timer.begin("弹幕")
            update(JobUpdate(stage: .danmaku, progress: nil, detail: "获取弹幕…", quality: quality))
            if w == 0 || h == 0, let probed = await ffmpeg.probeSize(merged) { (w, h, fps) = probed }
            if w == 0 || h == 0 { (w, h) = (1920, 1080) }
            // 重试时复用上次生成的 ASS（样式和分辨率没变的前提下），保证已渲染的分段仍然有效
            let assFile = tmp.appendingPathComponent("danmaku.ass")
            let keyFile = tmp.appendingPathComponent("danmaku.key")
            // 指纹必须稳定：JSONEncoder 默认不保证键顺序
            let styleEncoder = JSONEncoder()
            styleEncoder.outputFormatting = [.sortedKeys]
            let styleData = (try? styleEncoder.encode(settings.danmakuStyle)) ?? Data()
            let assKey = shortHash("\(DanmakuASS.cacheVersion)|\(e.cid)|\(w)x\(h)|" + String(decoding: styleData, as: UTF8.self))
            let ass: DanmakuASSResult
            if let saved = try? String(contentsOf: keyFile, encoding: .utf8), saved.hasPrefix(assKey + "|"),
               let text = try? String(contentsOf: assFile, encoding: .utf8) {
                let parts = saved.split(separator: "|").compactMap { Int($0) }
                ass = DanmakuASSResult(text: text, count: parts.first ?? 0, filtered: 0, dropped: 0)
                Log.info("复用上次生成的弹幕 ASS（\(ass.count) 条），跳过获取", tag: tag)
            } else {
                let comments = try await client.danmaku(cid: e.cid, aid: e.aid, duration: Double(s.durationMs) / 1000, tag: tag)
                if settings.saveXML {
                    try DanmakuXML.make(comments, cid: e.cid).write(to: dir.appendingPathComponent(name + ".xml"),
                                                                      atomically: true, encoding: .utf8)
                }
                let assWatch = Stopwatch()
                ass = DanmakuASS.make(comments, width: w, height: h, style: settings.danmakuStyle)
                Log.info("生成 ASS（\(w)×\(h)）用时 \(assWatch.text)：共 \(comments.count) 条，显示 \(ass.count) 条，"
                    + "过滤 \(ass.filtered) 条（高级弹幕/屏蔽），轨道放不下丢弃 \(ass.dropped) 条", tag: tag)
                try ass.text.write(to: assFile, atomically: true, encoding: .utf8)
                try "\(assKey)|\(ass.count)".write(to: keyFile, atomically: true, encoding: .utf8)
            }
            do {

                if settings.danmakuMode == .assFile || ass.count == 0 {
                    if ass.count > 0 {
                        try ass.text.write(to: dir.appendingPathComponent(name + ".ass"), atomically: true, encoding: .utf8)
                    }
                    notes.append(ass.count == 0 ? "无弹幕" : "弹幕 \(ass.count) 条")
                } else {
                    timer.begin("渲染")
                    let fpsLabel = settings.burn60fps ? "60fps" : "\(Int(fps.rounded()))fps"
                    let shown = ass.count
                    update(JobUpdate(stage: .rendering, progress: 0,
                                     detail: "渲染弹幕（\(shown) 条，\(fpsLabel)）…", quality: quality))
                    let burned = tmp.appendingPathComponent("burned.mp4")
                    let duration = Double(s.durationMs) / 1000
                    let watch = Stopwatch()
                    try await ffmpeg.burn(input: merged, assName: "danmaku.ass", workDir: tmp, output: burned,
                                          width: w, height: h, fps60: settings.burn60fps, sourceFPS: fps,
                                          encoder: settings.burnEncoder, quality: settings.burnQuality, duration: duration,
                                          segments: settings.burnSegments, renderer: settings.danmakuRenderer,
                                          hardwareBitrateKbps: settings.hardwareBitrateKbps > 0 ? settings.hardwareBitrateKbps : nil, tag: tag) { p, encoder in
                        // 优先用 ffmpeg 自报速度，没有时按已用时间估算
                        let speed = p.speed ?? (watch.elapsed > 1 ? p.outTime / watch.elapsed : 0)
                        var detail = "渲染弹幕 \(Int(p.fraction * 100))%"
                        if speed > 0 {
                            detail += String(format: " · %.1fx", speed)
                            detail += " · 剩余约 \(formatDuration((duration - p.outTime) / speed))"
                        }
                        detail += " · \(shown) 条 · \(fpsLabel) · \(encoder)"
                        update(JobUpdate(stage: .rendering, progress: p.fraction, detail: detail, quality: quality))
                    }
                    if settings.keepOriginal {
                        let raw = dir.appendingPathComponent(name + " (无弹幕).mp4")
                        try? fm.removeItem(at: raw)
                        try fm.moveItem(at: merged, to: raw)
                        try ass.text.write(to: dir.appendingPathComponent(name + " (无弹幕).ass"), atomically: true, encoding: .utf8)
                    }
                    outputFile = burned
                    outQuality = quality.replacingOccurrences(of: "\(Int(s.fps.rounded()))fps", with: fpsLabel)
                    notes.append("已烧录弹幕 \(shown) 条，渲染用时 \(watch.text)")
                }
            }
        }

        timer.begin("收尾")
        try fm.moveItem(at: outputFile, to: final)
        // 正常文件先落盘，分享压缩失败或取消后可直接从该文件重试，无需重新下载。
        var shareResult: JobResult?
        if settings.wechatShareEnabled {
            timer.begin("微信分享")
            shareResult = try await makeWechatShare(final, duration: Double(s.durationMs) / 1000, tag: tag, update: update)
        }
        try? fm.removeItem(at: tmp)
        // 临时目录空了就删掉
        let tmpRoot = tmp.deletingLastPathComponent()
        if (try? fm.contentsOfDirectory(atPath: tmpRoot.path))?.isEmpty == true { try? fm.removeItem(at: tmpRoot) }

        if let shareResult { notes.append(shareResult.note) }
        update(JobUpdate(stage: .finished, progress: 1, detail: "完成", quality: shareResult == nil ? outQuality : "微信分享 · \(settings.wechatShareOptions.speedLabel)倍"))
        return JobResult(file: shareResult?.file ?? final, skipped: false, note: notes.joined(separator: "，"))
    }

    private func makeWechatShare(_ input: URL, duration: Double?, tag: String,
                                 update: @escaping @Sendable (JobUpdate) -> Void) async throws -> JobResult {
        let options = settings.wechatShareOptions
        let output = options.outputURL(for: input)
        let sidecar = input.deletingPathExtension().appendingPathExtension("ass")
        let ass = settings.danmakuMode == .assFile && FileManager.default.fileExists(atPath: sidecar.path) ? sidecar : nil
        update(JobUpdate(stage: .rendering, progress: 0, detail: "微信分享：\(options.speedLabel)倍，压缩中…"))
        try await ffmpeg.exportWechatShare(input: input, output: output, options: options, ass: ass,
                                          sourceDuration: duration, tag: tag) { p in
            update(JobUpdate(stage: .rendering, progress: duration == nil ? nil : p.fraction,
                             detail: "微信分享：\(options.speedLabel)倍 · \(Int(p.fraction * 100))%"))
        }
        return JobResult(file: output, skipped: false, note: "已生成微信分享版（\(options.speedLabel)倍），保留正常版本")
    }

    private func download(_ s: StreamInfo, into tmp: URL, merged: URL, quality: String, tag: String,
                          timer: StageTimer, lease: PipelineLease, update: @escaping @Sendable (JobUpdate) -> Void) async throws {
        let fm = FileManager.default
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var got: [Int: Int64] = [:]
            var total: [Int: Int64] = [:]
            let watch = Stopwatch()
        }
        let counter = Counter()
        let report: @Sendable (Int, Int64, Int64) -> Void = { idx, got, total in
            let (g, t, elapsed) = counter.lock.withLock {
                counter.got[idx] = got
                counter.total[idx] = total
                return (counter.got.values.reduce(0, +), counter.total.values.reduce(0, +), counter.watch.elapsed)
            }
            var detail = "下载中 \(formatBytes(Double(g)))" + (t > 0 ? " / \(formatBytes(Double(t)))" : "")
            if elapsed > 0.5 {
                let rate = Double(g) / elapsed
                detail += " · \(formatBytes(rate))/s"
                if t > g, rate > 0 { detail += " · 剩余约 \(formatDuration(Double(t - g) / rate))" }
            }
            update(JobUpdate(stage: .downloading, progress: t > 0 ? Double(g) / Double(t) : nil, detail: detail, quality: quality))
        }
        update(JobUpdate(stage: .downloading, progress: 0, detail: "开始下载…", quality: quality))

        // 先合并到临时名，成功后再改名，保证 merged.mp4 一定是完整的
        let merging = tmp.appendingPathComponent("merging.mp4")
        if let segs = s.segments {
            var parts: [URL] = []
            for (i, urls) in segs.enumerated() {
                let p = tmp.appendingPathComponent("seg\(i)-\(s.qn).flv")
                if fm.fileExists(atPath: p.path) {
                    Log.info("分段\(i + 1)上次已下载完成，跳过", tag: tag)
                    report(i, fileSize(p), fileSize(p))
                    parts.append(p)
                    continue
                }
                try await FileDownload.fetch(urls: urls, to: p, label: "分段\(i + 1)", tag: tag) { g, t in report(i, g, t) }
                parts.append(p)
            }
            update(JobUpdate(stage: .merging, progress: nil, detail: "下载完成，等待合成通道…", quality: quality))
            try await lease.compose()
            Log.info("进入合成通道，允许下载下一个视频", tag: tag)
            timer.begin("合并")
            update(JobUpdate(stage: .merging, progress: nil, detail: "合并分段…", quality: quality))
            try await ffmpeg.concat(parts, output: merging, workDir: tmp, tag: tag)
            for p in parts { try? fm.removeItem(at: p) }
        } else {
            // 文件名带上流的标识：重试时只续传同一条流（换了清晰度/编码就重新下）
            let videoFile = tmp.appendingPathComponent("video-\(s.qn)-\(s.codec?.rawValue ?? "x").m4s")
            let audioFile = tmp.appendingPathComponent("audio-\(s.audioId).m4s")
            async let v: Void = fetchOnce(s.videoURLs, to: videoFile, label: "视频", tag: tag) { g, t in report(0, g, t) }
            if let a = s.audioURLs {
                async let au: Void = fetchOnce(a, to: audioFile, label: "音频", tag: tag) { g, t in report(1, g, t) }
                _ = try await (v, au)
            } else {
                try await v
            }
            let total = counter.lock.withLock { counter.got.values.reduce(0, +) }
            Log.info("下载完成 \(formatBytes(Double(total)))，用时 \(counter.watch.text)，平均 \(formatBytes(Double(total) / max(counter.watch.elapsed, 0.001)))/s", tag: tag)
            update(JobUpdate(stage: .merging, progress: nil, detail: "下载完成，等待合成通道…", quality: quality))
            try await lease.compose()
            Log.info("进入合成通道，允许下载下一个视频", tag: tag)
            timer.begin("合并")
            update(JobUpdate(stage: .merging, progress: nil, detail: "合并音视频…", quality: quality))
            let watch = Stopwatch()
            try await ffmpeg.merge(video: videoFile, audio: s.audioURLs == nil ? nil : audioFile, output: merging,
                                   codec: s.codec, tag: tag)
            Log.info("合并完成，用时 \(watch.text)", tag: tag)
            try? fm.removeItem(at: videoFile)
            try? fm.removeItem(at: audioFile)
        }
        try? fm.removeItem(at: merged)
        try fm.moveItem(at: merging, to: merged)
    }
}

/// 已完整下载（.part 已改名）的文件直接跳过
private func fetchOnce(_ urls: [String], to dest: URL, label: String, tag: String,
                       progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
    if FileManager.default.fileExists(atPath: dest.path) {
        let size = fileSize(dest)
        Log.info("\(label)上次已下载完成（\(formatBytes(Double(size)))），跳过", tag: tag)
        progress(size, size)
        return
    }
    try await FileDownload.fetch(urls: urls, to: dest, label: label, tag: tag, progress: progress)
}

/// 网络、CDN、风控、ffmpeg 这类临时性错误值得重试；视频不存在、无权限等不重试
public func isRetryable(_ error: Error) -> Bool {
    if let u = error as? URLError { return u.code != .cancelled }
    if let b = error as? BiliError {
        switch b {
        case let .http(code): return code >= 500 || [403, 408, 412, 416, 429].contains(code)
        case let .api(code, _): return [-352, -412, -500, -503, -509, -799].contains(code)
        case .downloadFailed, .ffmpegFailed: return true
        case .invalidInput, .noStream, .ffmpegMissing: return false
        }
    }
    let ns = error as NSError
    return ns.domain == NSPOSIXErrorDomain && [ETIMEDOUT, ECONNRESET, ENETDOWN, ENETUNREACH].contains(Int32(ns.code))
}

func fileSize(_ url: URL) -> Int64 {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
}
