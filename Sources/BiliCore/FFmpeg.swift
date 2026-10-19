import CryptoKit
import Foundation

/// ffmpeg -progress 输出的一帧状态
public struct FFProgress: Sendable {
    public var fraction: Double
    /// ffmpeg 报告的处理速度（相对实时，如 5.6 表示 5.6 倍速）
    public var speed: Double?
    public var fps: Double?
    public var outTime: Double
}

public struct FFmpeg: Sendable {
    public let path: String

    public static func locate(custom: String? = nil) -> FFmpeg? {
        var candidates: [String] = []
        if let custom, !custom.isEmpty { candidates.append(custom) }
        // 打包进 .app 的 ffmpeg 优先
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("ffmpeg").path { candidates.append(bundled) }
        candidates += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) { return FFmpeg(path: p) }
        return nil
    }

    public var version: String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-hide_banner", "-version"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "?" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? "?"
    }

    /// 运行 ffmpeg。duration 已知时通过 -progress 回调进度（含 ffmpeg 自报的 fps/速度）。任务取消时会终止进程。
    public func run(_ args: [String], cwd: URL? = nil, duration: Double? = nil, tag: String? = nil,
                    progress: (@Sendable (FFProgress) -> Void)? = nil) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        let fullArgs = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats"] + args
        process.arguments = fullArgs
        if let cwd { process.currentDirectoryURL = cwd }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        Log.debug("ffmpeg \(fullArgs.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " "))"
            + (cwd.map { "  (cwd: \($0.path))" } ?? ""), tag: tag)

        final class Buffer: @unchecked Sendable {
            let lock = NSLock()
            var stderr = Data()
            var pending = ""
            var block: [String: String] = [:]
        }
        let buf = Buffer()

        out.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            guard !chunk.isEmpty, let progress else { return }
            let reports: [FFProgress] = buf.lock.withLock {
                buf.pending += String(decoding: chunk, as: UTF8.self)
                var lines = buf.pending.split(separator: "\n", omittingEmptySubsequences: false)
                buf.pending = String(lines.removeLast())
                var result: [FFProgress] = []
                for line in lines {
                    let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard kv.count == 2 else { continue }
                    buf.block[kv[0]] = kv[1]
                    // 每个进度块以 progress=continue/end 结尾
                    guard kv[0] == "progress" else { continue }
                    let us = Double(buf.block["out_time_us"] ?? buf.block["out_time_ms"] ?? "") ?? 0
                    let t = max(0, us / 1_000_000)
                    let total = duration ?? 0
                    let speed = Double((buf.block["speed"] ?? "").replacingOccurrences(of: "x", with: ""))
                    result.append(FFProgress(fraction: total > 0 ? min(1, t / total) : 0, speed: speed,
                                             fps: Double(buf.block["fps"] ?? ""), outTime: t))
                }
                return result
            }
            for r in reports { progress(r) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            buf.lock.withLock {
                buf.stderr.append(chunk)
                if buf.stderr.count > 16_384 { buf.stderr = buf.stderr.suffix(8192) }
            }
        }

        let watch = Stopwatch()
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            guard process.isRunning else { return }
            process.terminate()
            // 卡在 VideoToolbox 调用里的 ffmpeg 不响应 SIGTERM（实测拖了 100 秒），3 秒后强杀
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if process.isRunning {
                    Log.warn("ffmpeg (pid \(pid)) 未响应 SIGTERM，强制结束", tag: tag)
                    kill(pid, SIGKILL)
                }
            }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        let stderrText = buf.lock.withLock { String(decoding: buf.stderr, as: UTF8.self) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if Task.isCancelled {
            Log.info("ffmpeg 已终止（任务取消），运行了 \(watch.text)", tag: tag)
            throw CancellationError()
        }
        if status != 0 {
            Log.error("ffmpeg 退出码 \(status)，用时 \(watch.text)，stderr:\n"
                + stderrText.split(separator: "\n").suffix(15).joined(separator: "\n"), tag: tag)
            let msg = stderrText.split(separator: "\n").suffix(3).joined(separator: "\n")
            throw BiliError.ffmpegFailed(msg.isEmpty ? "退出码 \(status)" : msg)
        }
        if !stderrText.isEmpty {
            Log.warn("ffmpeg 输出: \(stderrText.split(separator: "\n").suffix(8).joined(separator: " | "))", tag: tag)
        }
    }

    /// 合并 DASH 音视频，不重新编码
    public func merge(video: URL, audio: URL?, output: URL, codec: VideoCodec?, tag: String? = nil) async throws {
        var args = ["-i", video.path]
        if let audio { args += ["-i", audio.path, "-map", "0:v:0", "-map", "1:a:0"] }
        args += ["-c", "copy"]
        // QuickTime/Finder 只认 hvc1 标签的 HEVC
        if codec == .hevc { args += ["-tag:v", "hvc1"] }
        args += ["-movflags", "+faststart", "-f", "mp4", output.path]
        try await run(args, tag: tag)
    }

    /// 拼接老式分段视频
    public func concat(_ parts: [URL], output: URL, workDir: URL, tag: String? = nil) async throws {
        let list = parts.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n")
        let listURL = workDir.appendingPathComponent("concat.txt")
        try list.write(to: listURL, atomically: true, encoding: .utf8)
        try await run(["-f", "concat", "-safe", "0", "-i", listURL.path, "-c", "copy", "-movflags", "+faststart",
                       "-f", "mp4", output.path], tag: tag)
    }

    public func probeSize(_ file: URL) async -> (Int, Int, Double)? {
        let probe = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: probe.path) else { return nil }
        let p = Process()
        p.executableURL = probe
        p.arguments = ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height,r_frame_rate",
                       "-of", "csv=p=0", file.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let f = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
        guard f.count >= 3, let w = Int(f[0]), let h = Int(f[1]) else { return nil }
        let r = f[2].split(separator: "/").compactMap { Double($0) }
        return (w, h, r.count == 2 && r[1] > 0 ? r[0] / r[1] : 0)
    }
}

public enum BurnEncoder: String, Codable, CaseIterable, Sendable, Identifiable {
    case x264, h264, hevc
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .x264: "软件编码（推荐，按「输出体积」设置）"
        case .h264: "H.264 硬件编码（VideoToolbox）"
        case .hevc: "H.265 硬件编码（VideoToolbox）"
        }
    }
    var isHardware: Bool { self != .x264 }
}

/// 软件编码的体积/速度档位。
///
/// 实测（20 秒 1080P60 片段，VMAF 对比无损渲染结果；体积/CPU 均相对「速度优先」）：
///
/// | 档位 | 参数 | 密集弹幕 体积 / VMAF | 稀疏弹幕 体积 / VMAF | 编码 CPU |
/// |---|---|---|---|---|
/// | 速度优先 | x264 veryfast crf23 | 18.1Mbps / 99.60 | 2.5Mbps / 91.55 | 1x |
/// | 均衡 | x264 faster crf25 | -21% / 99.50 | -8% / 92.66 | 1.4x |
/// | 体积优先 | x264 medium crf26 | -32% / 99.55 | -20% / 92.83 | 2.1x |
/// | 最小体积 | x265 fast crf26 | -34% / 99.66 | -40% / 93.51 | 4~5x |
///
/// 只提高 crf 不换 preset 会掉画质（veryfast crf26 密集弹幕 VMAF 掉到 94），所以档位同时调 preset 和 crf。
public enum BurnQuality: String, Codable, CaseIterable, Sendable, Identifiable {
    case speed, balanced, size, smallest
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .speed: "速度优先（体积最大）"
        case .balanced: "均衡（小 10~20%）"
        case .size: "体积优先（小 20~30%，推荐）"
        case .smallest: "最小体积 H.265（小 35~40%，很慢）"
        }
    }

    func args(threads: Int) -> [String] {
        switch self {
        case .speed: ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-threads", String(threads)]
        case .balanced: ["-c:v", "libx264", "-preset", "faster", "-crf", "25", "-threads", String(threads)]
        case .size: ["-c:v", "libx264", "-preset", "medium", "-crf", "26", "-threads", String(threads)]
        case .smallest: ["-c:v", "libx265", "-preset", "fast", "-crf", "26", "-tag:v", "hvc1",
                         "-x265-params", "log-level=error:pools=\(threads)"]
        }
    }

    var shortLabel: String {
        switch self {
        case .speed: "x264 veryfast crf23"
        case .balanced: "x264 faster crf25"
        case .size: "x264 medium crf26"
        case .smallest: "x265 fast crf26"
        }
    }
}

public extension FFmpeg {
    /// 自动选择的并行段数：短视频不切；长视频按核数切，最多 4 段
    static func autoSegments(duration: Double) -> Int {
        guard duration >= 90 else { return 1 }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return max(1, min(4, cores / 2 - 1, Int(duration / 45)))
    }

    /// 把 ASS 弹幕烧录进画面。fps60 时先补帧到 60fps 再渲染字幕，弹幕滚动更顺滑。
    ///
    /// 实测（M1 Pro，1080P25 → 60fps，20 秒片段）：
    /// - 弹幕稀疏（约 70 条/分钟）：libass 渲染约 7x，瓶颈在 x264 编码，整体约 5.6x；
    /// - 弹幕密集（约 1300 条/分钟）：瓶颈变成 libass（单线程，只有 0.88x，换编码器无差别，描边约占一半开销），
    ///   切成 4 段并行渲染可到 2.56x。所以长视频按时间切段并行，最后无损拼接并接回原音轨。
    /// - VideoToolbox 在硬件编码器被其它进程占用时会掉到 0.01~0.04x 甚至报错，所以默认用软件编码；
    ///   选择硬件编码时带看门狗（独立计时，不依赖 ffmpeg 输出），20 秒后整体仍低于 0.5x 就改用软件编码。
    func burn(input: URL, assName: String, workDir: URL, output: URL, width: Int, height: Int,
              fps60: Bool, sourceFPS: Double, encoder: BurnEncoder, quality: BurnQuality = .size,
              duration: Double, segments: Int = 0, renderer: DanmakuRenderer = .libass, hardwareBitrateKbps: Int? = nil,
              tag: String? = nil, progress: @escaping @Sendable (FFProgress, String) -> Void) async throws {
        let outFPS = fps60 ? 60 : (sourceFPS > 0 ? sourceFPS : 30)
        let pixels = Double(max(width, 1) * max(height, 1))
        let bpp = encoder == .hevc ? 0.065 : 0.1
        let kbps = max(500, hardwareBitrateKbps ?? max(2500, Int(pixels * outFPS * bpp / 1000)))
        let n = segments > 0 ? segments : (renderer == .metal && encoder.isHardware ? 1 : Self.autoSegments(duration: duration))
        let cores = ProcessInfo.processInfo.activeProcessorCount

        func encoderArgs(_ e: BurnEncoder) -> [String] {
            switch e {
            case .x264:
                return quality.args(threads: max(2, cores / n))
            case .h264:
                return ["-c:v", "h264_videotoolbox", "-profile:v", "high", "-b:v", "\(kbps)k", "-maxrate", "\(kbps * 3 / 2)k"]
            case .hevc:
                return ["-c:v", "hevc_videotoolbox", "-tag:v", "hvc1", "-b:v", "\(kbps)k", "-maxrate", "\(kbps * 3 / 2)k"]
            }
        }
        let label: (BurnEncoder) -> String = { e in
            let name = e == .x264 ? quality.shortLabel : e == .h264 ? "h264_videotoolbox" : "hevc_videotoolbox"
            let pipeline = renderer == .metal ? "Metal + \(name)" : name
            return n > 1 ? "\(pipeline)×\(n)" : pipeline
        }

        Log.info("烧录参数：\(width)×\(height) → \(Int(outFPS))fps，绘制 \(renderer.rawValue)，编码 \(encoder.rawValue)，并行 \(n) 段，"
            + (encoder.isHardware ? "目标码率 \(kbps)kbps" : "档位 \(quality.rawValue)（\(quality.shortLabel)）"), tag: tag)

        do {
            try await render(input: input, assName: assName, workDir: workDir, output: output, fps60: fps60,
                             encoder: encoderArgs(encoder), hardware: encoder.isHardware, segments: n, renderer: renderer, outputFPS: outFPS,
                             duration: duration, label: label(encoder), tag: tag, progress: progress)
        } catch {
            try Task.checkCancellation()
            if renderer == .metal, case BiliError.invalidInput = error {
                Log.warn("Metal 不支持当前输入，回退 libass：\(error.localizedDescription)", tag: tag)
                try await burn(input: input, assName: assName, workDir: workDir, output: output,
                    width: width, height: height, fps60: fps60, sourceFPS: sourceFPS, encoder: encoder,
                    quality: quality, duration: duration, segments: segments, renderer: .libass,
                    hardwareBitrateKbps: hardwareBitrateKbps, tag: tag, progress: progress)
                return
            }
            guard encoder.isHardware else { throw error }
            let reason = (error as? WatchdogTripped)?.reason ?? "硬件编码失败：\(error.localizedDescription)"
            Log.warn("改用软件编码 \(quality.shortLabel)：\(reason)", tag: tag)
            try await render(input: input, assName: assName, workDir: workDir, output: output, fps60: fps60,
                             encoder: encoderArgs(.x264), hardware: false, segments: n, renderer: renderer, outputFPS: outFPS,
                             duration: duration, label: label(.x264), tag: tag, progress: progress)
        }
    }

    private struct WatchdogTripped: Error { let reason: String }

    private func render(input: URL, assName: String, workDir: URL, output: URL, fps60: Bool, encoder: [String],
                        hardware: Bool, segments n: Int, renderer: DanmakuRenderer, outputFPS: Double, duration: Double, label: String, tag: String?,
                        progress: @escaping @Sendable (FFProgress, String) -> Void) async throws {
        let fm = FileManager.default
        let segLen = n > 1 ? (duration / Double(n)).rounded(.up) : duration
        // libass 的 CoreText 匹配会把得意黑拉丁字形回退到 Helvetica；直接加载字体并用内部中文族名。
        let assText = try String(contentsOf: workDir.appendingPathComponent(assName), encoding: .utf8)
        var fontFilter = ""
        if assText.contains("Style: Danmaku,得意黑,") {
            let candidates = [
                fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts/SmileySans-Oblique.ttf"),
                URL(fileURLWithPath: "/Library/Fonts/SmileySans-Oblique.ttf")
            ]
            guard let source = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
                throw BiliError.invalidInput("未找到得意黑字体文件 SmileySans-Oblique.ttf，请先安装字体")
            }
            let fonts = workDir.appendingPathComponent("ass-fonts", isDirectory: true)
            try fm.createDirectory(at: fonts, withIntermediateDirectories: true)
            let target = fonts.appendingPathComponent(source.lastPathComponent)
            try? fm.removeItem(at: target)
            try fm.copyItem(at: source, to: target)
            fontFilter = ":fontsdir=ass-fonts"
        }

        // 每段先把时间戳平移回原视频位置再渲染弹幕，渲染后归零，保证弹幕时间对齐
        func filters(_ start: Double) -> String {
            var f: [String] = []
            if start > 0 { f.append("setpts=PTS+\(start)/TB") }
            if fps60 { f.append("fps=60") }
            f.append("ass=\(assName)\(fontFilter)")
            if start > 0 { f.append("setpts=PTS-STARTPTS") }
            f.append("format=yuv420p")
            return f.joined(separator: ",")
        }

        // 分段文件名带上参数指纹：重试时只复用参数完全一致、且已完整渲染（已改名）的分段
        let assData = (try? Data(contentsOf: workDir.appendingPathComponent(assName))) ?? Data()
        let encoderKey = encoder.enumerated().filter { $0.offset == 0 || encoder[$0.offset - 1] != "-threads" }
            .map(\.element).filter { $0 != "-threads" }
        let renderKey = renderer == .metal ? "metal-nv12-v2" : renderer.rawValue
        let key = shortHash("\(renderKey)|\(n)|\(segLen)|\(fps60)|\(encoderKey)|\(fileSize(input))|" + shortHash(assData))
        let segFiles = (0 ..< n).map { workDir.appendingPathComponent("seg-\(key)-\($0).mp4") }
        let segLens = (0 ..< n).map { i in i < n - 1 ? segLen : max(0, duration - segLen * Double(n - 1)) }
        let reused = Set((0 ..< n).filter { fm.fileExists(atPath: segFiles[$0].path) })

        final class Agg: @unchecked Sendable {
            let lock = NSLock()
            var outTime: [Double]
            var fps: [Double]
            var nextDecile = 1
            var tripped: String?
            init(_ n: Int) {
                outTime = Array(repeating: 0, count: n)
                fps = Array(repeating: 0, count: n)
            }
            var total: Double { lock.withLock { outTime.reduce(0, +) } }
        }
        let agg = Agg(n)
        for i in reused { agg.outTime[i] = segLens[i] }
        let reusedTime = agg.total
        let watch = Stopwatch()
        Log.info("开始编码 [\(label)]，视频时长 \(formatDuration(duration))\(n > 1 ? "，每段 \(formatDuration(segLen))" : "")"
            + (reused.isEmpty ? "" : "，复用上次已完成的 \(reused.count)/\(n) 段"), tag: tag)

        let work = Task { () -> [Error] in
            await withTaskGroup(of: Error?.self) { group in
                for i in 0 ..< n where !reused.contains(i) {
                    let start = Double(i) * segLen
                    let partial = workDir.appendingPathComponent("seg-\(key)-\(i).part.mp4")
                    var args: [String] = []
                    if start > 0 { args += ["-ss", String(format: "%.3f", start)] }
                    if i < n - 1 { args += ["-t", String(format: "%.3f", segLen)] }
                    // 只渲染画面，最后统一接回原音轨
                    args += ["-i", input.path, "-vf", filters(start), "-map", "0:v:0", "-an"] + encoder + [partial.path]
                    let segTag = n > 1 ? "\(tag ?? "")#\(i + 1)" : tag
                    group.addTask {
                        let segWatch = Stopwatch()
                        do {
                            let report: @Sendable (FFProgress) -> Void = { p in
                                let (sum, fpsSum, decile) = agg.lock.withLock { () -> (Double, Double, Int?) in
                                    agg.outTime[i] = p.outTime
                                    agg.fps[i] = p.fps ?? agg.fps[i]
                                    let sum = agg.outTime.reduce(0, +)
                                    let d = Int(sum / max(duration, 0.001) * 10)
                                    var hit: Int?
                                    if d >= agg.nextDecile && d < 10 {
                                        agg.nextDecile = d + 1
                                        hit = d
                                    }
                                    return (sum, agg.fps.reduce(0, +), hit)
                                }
                                let speed = (sum - reusedTime) / max(watch.elapsed, 0.001)
                                progress(FFProgress(fraction: min(1, sum / max(duration, 0.001)), speed: speed,
                                                    fps: fpsSum, outTime: sum), label)
                                if let d = decile {
                                    Log.info(String(format: "编码 %d%% · 已用 %@ · 合计 %.0f fps · %.2fx", d * 10, watch.text, fpsSum, speed), tag: tag)
                                }
                            }
                            if renderer == .metal {
                                try await MetalDanmaku.segment(ffmpeg: self, input: input,
                                    ass: workDir.appendingPathComponent(assName), output: partial,
                                    start: start, duration: segLens[i], fps: outputFPS,
                                    encoder: encoder, tag: segTag, progress: report)
                            } else {
                                try await self.run(args, cwd: workDir, duration: duration, tag: segTag, progress: report)
                            }
                            try? fm.removeItem(at: segFiles[i])
                            try fm.moveItem(at: partial, to: segFiles[i])
                            if n > 1 { Log.info("分段 \(i + 1)/\(n) 完成，用时 \(segWatch.text)", tag: tag) }
                            return nil
                        } catch {
                            try? fm.removeItem(at: partial)
                            if !(error is CancellationError) {
                                Log.error("分段 \(i + 1)/\(n) 失败（\(segWatch.text)），其余分段继续：\(error.localizedDescription)", tag: tag)
                            }
                            return error
                        }
                    }
                }
                var errors: [Error] = []
                for await e in group { if let e { errors.append(e) } }
                return errors
            }
        }

        // 看门狗独立计时：硬件编码器被占满时 ffmpeg 可能长时间没有任何进度输出
        let dog: Task<Void, Never>? = hardware ? Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, watch.elapsed > 20 else { continue }
                let speed = (agg.total - reusedTime) / watch.elapsed
                if speed < 0.5 {
                    agg.lock.withLock {
                        agg.tripped = String(format: "硬件编码 %.0f 秒后整体速度仅 %.2fx，硬件编码器可能被其它程序占用", watch.elapsed, speed)
                    }
                    work.cancel()
                    return
                }
            }
        } : nil
        defer { dog?.cancel() }

        let errors = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        try Task.checkCancellation()
        if let reason = agg.lock.withLock({ agg.tripped }) { throw WatchdogTripped(reason: reason) }
        if let first = errors.first {
            let done = (0 ..< n).filter { fm.fileExists(atPath: segFiles[$0].path) }.count
            Log.warn("渲染未完成：\(errors.count) 段失败，\(done)/\(n) 段已完成并保留，重试时会跳过", tag: tag)
            throw first
        }

        // 拼接（单段也走这里，顺便接回原音轨）
        let concatWatch = Stopwatch()
        let list = segFiles.map { "file '\($0.lastPathComponent)'" }.joined(separator: "\n")
        try list.write(to: workDir.appendingPathComponent("segments.txt"), atomically: true, encoding: .utf8)
        try? fm.removeItem(at: output)
        try await run(["-f", "concat", "-safe", "0", "-i", "segments.txt", "-i", input.path,
                       "-map", "0:v:0", "-map", "1:a?", "-c", "copy", "-movflags", "+faststart", output.path],
                      cwd: workDir, tag: tag)
        for f in segFiles { try? fm.removeItem(at: f) }
        Log.info("拼接 \(n) 段并接回音轨，用时 \(concatWatch.text)", tag: tag)

        let size = (try? fm.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
        Log.info(String(format: "编码完成 [%@] 用时 %@ · 平均 %.2fx 实时 · 输出 %@（%.1f Mbps）", label, watch.text,
                        (duration - reusedTime) / max(watch.elapsed, 0.001), formatBytes(Double(size)),
                        duration > 0 ? Double(size) * 8 / duration / 1_000_000 : 0), tag: tag)
    }
}

func shortHash(_ s: String) -> String { shortHash(Data(s.utf8)) }

func shortHash(_ d: Data) -> String {
    SHA256.hash(data: d).prefix(6).map { String(format: "%02x", $0) }.joined()
}
