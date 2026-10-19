import AVFoundation
import CoreText
import Metal
import VideoToolbox
import Foundation

public enum DanmakuRenderer: String, Codable, CaseIterable, Sendable, Identifiable {
    case libass, metal
    public var id: String { rawValue }
    public var label: String { self == .metal ? "Metal GPU（实验）" : "libass CPU（兼容模式）" }
}

/// 仅解析本程序生成的 ASS 子集，不用于任意外部 ASS 特效。
struct MetalCue {
    let start: Double, end: Double
    let text: String
    let size: Double
    let color: Int
    let outlineColor: Int
    let x1: Double, y1: Double, x2: Double, y2: Double
    let centered: Bool
    func position(at time: Double) -> CGPoint {
        let t = min(1, max(0, (time - start) / max(end - start, 0.001)))
        return CGPoint(x: x1 + (x2 - x1) * t, y: y1 + (y2 - y1) * t)
    }
}

struct MetalTimeline {
    let width: Int, height: Int
    let font: String
    let opacity: Double, outlineOpacity: Double, outline: Double
    let cues: [MetalCue]

    static func seconds(_ s: String) -> Double {
        let p = s.split(separator: ":").compactMap { Double($0) }
        return p.count == 3 ? p[0] * 3600 + p[1] * 60 + p[2] : 0
    }

    init(_ ass: String) throws {
        var expressions: [String: NSRegularExpression] = [:]
        func capture(_ pattern: String, _ text: String) -> [String]? {
            let re: NSRegularExpression
            if let cached = expressions[pattern] { re = cached }
            else {
                guard let compiled = try? NSRegularExpression(pattern: pattern) else { return nil }
                expressions[pattern] = compiled; re = compiled
            }
            guard let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
        func color(_ s: String) -> Int { Int(s.replacingOccurrences(of: "&H", with: "").replacingOccurrences(of: "&", with: ""), radix: 16) ?? 0 }
        let lines = ass.components(separatedBy: .newlines)
        width = lines.first { $0.hasPrefix("PlayResX:") }.flatMap { Int($0.dropFirst("PlayResX:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        height = lines.first { $0.hasPrefix("PlayResY:") }.flatMap { Int($0.dropFirst("PlayResY:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        guard width > 0, height > 0, let style = lines.first(where: { $0.hasPrefix("Style: Danmaku,") }) else {
            throw BiliError.invalidInput("Metal 只支持本程序生成的弹幕 ASS")
        }
        let fields = style.dropFirst(7).components(separatedBy: ",")
        guard fields.count >= 23 else { throw BiliError.invalidInput("ASS 样式不完整") }
        font = fields[1]
        let size = Double(fields[2]) ?? 40
        let primary = color(fields[3]), border = color(fields[5])
        opacity = 1 - Double((primary >> 24) & 255) / 255
        outlineOpacity = 1 - Double((border >> 24) & 255) / 255
        outline = Double(fields[16]) ?? 2
        var parsed: [MetalCue] = []
        for line in lines where line.hasPrefix("Dialogue:") {
            let p = line.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
            guard p.count == 10, let close = p[9].firstIndex(of: "}") else { throw BiliError.invalidInput("Metal 不支持该 ASS 事件") }
            let tags = String(p[9][...close])
            let values: [Double]
            let center: Bool
            if let m = capture(#"\\move\(([-\d.]+),([-\d.]+),([-\d.]+),([-\d.]+)\)"#, tags) {
                values = m.compactMap(Double.init); center = false
            } else if let m = capture(#"\\pos\(([-\d.]+),([-\d.]+)\)"#, tags) {
                let v = m.compactMap(Double.init); values = v + v; center = true
            } else { throw BiliError.invalidInput("Metal 不支持该 ASS 定位") }
            guard values.count == 4 else { throw BiliError.invalidInput("ASS 定位不完整") }
            let text = String(p[9][p[9].index(after: close)...])
                .replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\h", with: " ")
                .replacingOccurrences(of: "\\{", with: "{").replacingOccurrences(of: "\\}", with: "}")
                .replacingOccurrences(of: "\\\u{200B}", with: "\\")
            let fs = capture(#"\\fs([\d.]+)"#, tags)?.first.flatMap(Double.init) ?? size
            let c = capture(#"\\c&H([0-9A-Fa-f]+)&"#, tags)?.first.flatMap { Int($0, radix: 16) } ?? (primary & 0xFFFFFF)
            let b = capture(#"\\3c&H([0-9A-Fa-f]+)&"#, tags)?.first.flatMap { Int($0, radix: 16) } ?? (border & 0xFFFFFF)
            parsed.append(MetalCue(start: Self.seconds(p[1]), end: Self.seconds(p[2]), text: text, size: fs,
                                   color: c, outlineColor: b, x1: values[0], y1: values[1], x2: values[2], y2: values[3], centered: center))
        }
        cues = parsed.sorted { $0.start < $1.start }
    }
}

private struct MetalSprite {
    let image: CGImage
    let width: Double, height: Double
    let padding: Double
}

/// 字形只栅格化一次并缓存；每帧的位置变换、透明混合、色彩转换由原生 Metal 单通道执行。
public enum MetalDanmaku {
    private static func sprite(_ cue: MetalCue, timeline: MetalTimeline) throws -> MetalSprite {
        let name = timeline.font == "得意黑" ? "SmileySans-Oblique" : timeline.font
        var font = CTFontCreateWithName(name as CFString, cue.size, nil)
        if let bold = CTFontCreateCopyWithSymbolicTraits(font, cue.size, nil, .traitBold, .traitBold) { font = bold }
        // ASS 字号按 ascent+descent 归一化；CoreText 原始字号按 em，直接使用会大约放大 20%。
        let metricHeight = CTFontGetAscent(font) + CTFontGetDescent(font)
        if metricHeight > 0 { font = CTFontCreateCopyWithAttributes(font, cue.size * cue.size / metricHeight, nil, nil) }
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]
        let lines = cue.text.components(separatedBy: "\n").map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attrs)) }
        let pad = ceil(timeline.outline + 5)
        let lineHeight = cue.size * 1.2
        let textWidth = lines.map { CTLineGetTypographicBounds($0, nil, nil, nil) }.max() ?? 1
        let w = Int(ceil(textWidth + pad * 2)), h = Int(ceil(lineHeight * Double(lines.count) + pad * 2))
        guard w > 0, h > 0, w < 16384, h < 16384,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw BiliError.invalidInput("弹幕字形尺寸超出 GPU 限制")
        }
        func rgb(_ bgr: Int) -> CGColor {
            CGColor(colorSpace: ctx.colorSpace!, components: [CGFloat(bgr & 255)/255,
                CGFloat((bgr >> 8) & 255)/255, CGFloat((bgr >> 16) & 255)/255, 1])!
        }
        for (i, line) in lines.enumerated() {
            let y = Double(h) - pad - CTFontGetAscent(font) - Double(i) * lineHeight
            ctx.textPosition = CGPoint(x: pad, y: y)
            ctx.setTextDrawingMode(.stroke)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(timeline.outline * 2)
            ctx.setStrokeColor(rgb(cue.outlineColor))
            ctx.setAlpha(timeline.outlineOpacity)
            CTLineDraw(line, ctx)
            ctx.textPosition = CGPoint(x: pad, y: y)
            ctx.setTextDrawingMode(.fill)
            ctx.setFillColor(rgb(cue.color))
            ctx.setAlpha(timeline.opacity)
            CTLineDraw(line, ctx)
        }
        guard let cg = ctx.makeImage() else { throw BiliError.invalidInput("无法生成弹幕纹理") }
        return MetalSprite(image: cg, width: textWidth, height: Double(h), padding: pad)
    }

    /// 硬件编码直接接收共享帧缓冲；软件编码通过 ffmpeg 原始帧管道，均不写中间无损视频。
    public static func segment(ffmpeg: FFmpeg, input: URL, ass: URL, output: URL, start: Double, duration: Double,
                        fps: Double, encoder: [String], tag: String?,
                        progress: @escaping @Sendable (FFProgress) -> Void) async throws {
        let process = Process()
        let child = Task.detached(priority: .userInitiated) {
            try await self.renderSegment(ffmpeg: ffmpeg, process: process, input: input, ass: ass, output: output,
                                         start: start, duration: duration, fps: fps, encoder: encoder, tag: tag, progress: progress)
        }
        try await withTaskCancellationHandler {
            try await child.value
        } onCancel: {
            child.cancel()
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }

    private static func renderSegment(ffmpeg: FFmpeg, process: Process, input: URL, ass: URL, output: URL,
                                      start: Double, duration: Double, fps: Double, encoder: [String], tag: String?,
                                      progress: @escaping @Sendable (FFProgress) -> Void) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw BiliError.invalidInput("Metal GPU 不可用") }
        let timeline = try MetalTimeline(String(contentsOf: ass, encoding: .utf8))
        let asset = AVURLAsset(url: input)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw BiliError.noStream("无视频轨") }
        let descriptions = try await track.load(.formatDescriptions)
        for description in descriptions {
            if let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any],
               let transfer = extensions[kCVImageBufferTransferFunctionKey as String] as? String,
               [kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String, kCVImageBufferTransferFunction_ITU_R_2100_HLG as String].contains(transfer) {
                throw BiliError.invalidInput("Metal 实验路径暂不支持 HDR，请使用 libass")
            }
        }
        let transform = try await track.load(.preferredTransform)
        guard transform == .identity else { throw BiliError.invalidInput("实验 Metal 路径暂不支持旋转视频，请使用 CPU 模式") }
        let size = try await track.load(.naturalSize)
        let width = Int(size.width), height = Int(size.height)
        guard width == timeline.width, height == timeline.height else { throw BiliError.invalidInput("视频与弹幕尺寸不一致") }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000),
                                       duration: CMTime(seconds: duration, preferredTimescale: 60000))
        let source = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        source.alwaysCopiesSampleData = false
        reader.add(source)
        let compositor = try MetalCompositor(device: device, width: width, height: height)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary,
                                  &buffer) == kCVReturnSuccess, let buffer else { throw BiliError.invalidInput("无法分配 GPU 帧缓冲") }
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: ffmpeg.path)
        process.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-f", "rawvideo", "-pixel_format", "bgra",
                             "-video_size", "\(width)x\(height)", "-framerate", String(fps), "-i", "pipe:0", "-an",
                             "-pix_fmt", "yuv420p", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"] + encoder + [output.path]
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        let logURL = output.appendingPathExtension("encoder.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        process.standardError = log
        let hardware = encoder.contains("h264_videotoolbox") || encoder.contains("hevc_videotoolbox")
        var writer: AVAssetWriter?
        var writerInput: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        try Task.checkCancellation()
        if hardware {
            try? FileManager.default.removeItem(at: output)
            let native = try AVAssetWriter(outputURL: output, fileType: .mp4)
            let codec: AVVideoCodecType = encoder.contains("hevc_videotoolbox") ? .hevc : .h264
            let bitIndex = encoder.firstIndex(of: "-b:v")
            let rate = bitIndex.flatMap { Int(encoder[$0 + 1].replacingOccurrences(of: "k", with: "")) }.map { $0 * 1000 } ?? 8_000_000
            var compression: [String: Any] = [AVVideoAverageBitRateKey: rate,
                AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalKey: Int(fps * 2)]
            if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true],
                AVVideoCompressionPropertiesKey: compression,
                AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
            ])
            video.expectsMediaDataInRealTime = false
            let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true
            ])
            native.add(video)
            guard native.startWriting() else { throw native.error ?? BiliError.ffmpegFailed("无法启动硬件编码") }
            native.startSession(atSourceTime: .zero)
            writer = native; writerInput = video; adaptor = adapter
        } else {
            try process.run()
            _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        }
        defer {
            reader.cancelReading()
            if writer?.status == .writing { writer?.cancelWriting() }
            try? pipe.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
            try? log.close()
        }
        guard reader.startReading() else { throw reader.error ?? BiliError.noStream("无法解码视频") }
        Log.info("Metal GPU 绘制：\(device.name)，\(width)×\(height) @\(fps)，起点 \(start)s，时长 \(duration)s，输出 \(hardware ? "NV12 → 硬件编码" : "BGRA → 软件编码")", tag: tag)
        let watch = Stopwatch()
        var current = source.copyNextSampleBuffer()
        var next = source.copyNextSampleBuffer()
        var cursor = 0
        while cursor < timeline.cues.count && timeline.cues[cursor].end <= start { cursor += 1 }
        var active: [(MetalCue, MetalSprite, MTLTexture)] = []
        let frames = Int(ceil(duration * fps))
        // pixelBufferPool 的 getter 会进入 VTCompressionSessionGetPixelBufferPool；只获取一次。
        let pixelPool = adaptor?.pixelBufferPool
        if hardware && pixelPool == nil { throw BiliError.invalidInput("编码帧缓冲池不可用") }
        var pending: [(MTLCommandBuffer, CVPixelBuffer, Int)] = []
        var submittedFrames = 0
        var lastReport = 0.0
        var gpuWait = 0.0, writerWait = 0.0, appendTime = 0.0
        func appendOldest() async throws {
            let (command, pixel, index) = pending.removeFirst()
            let beginGPU = ProcessInfo.processInfo.systemUptime
            await command.completed()
            gpuWait += ProcessInfo.processInfo.systemUptime - beginGPU
            if let error = command.error { throw error }
            let beginWriter = ProcessInfo.processInfo.systemUptime
            while writerInput?.isReadyForMoreMediaData == false {
                try Task.checkCancellation()
                if writer?.status == .failed { throw writer?.error ?? BiliError.ffmpegFailed("硬件编码失败") }
                try await Task.sleep(for: .microseconds(200), tolerance: .zero)
            }
            writerWait += ProcessInfo.processInfo.systemUptime - beginWriter
            try Task.checkCancellation()
            let beginAppend = ProcessInfo.processInfo.systemUptime
            guard adaptor?.append(pixel, withPresentationTime: CMTime(seconds: Double(index) / fps, preferredTimescale: 60000)) == true else {
                throw writer?.error ?? BiliError.ffmpegFailed("硬件编码提交帧失败")
            }
            appendTime += ProcessInfo.processInfo.systemUptime - beginAppend
            submittedFrames = index + 1
        }
        for frame in 0..<frames {
            try Task.checkCancellation()
            if reader.status == .failed { throw reader.error ?? BiliError.noStream("视频解码失败") }
            let absolute = start + Double(frame) / fps
            while let n = next, CMSampleBufferGetPresentationTimeStamp(n).seconds <= absolute + 0.00001 {
                current = n
                next = source.copyNextSampleBuffer()
            }
            guard let current, let imageBuffer = CMSampleBufferGetImageBuffer(current) else {
                throw reader.error ?? BiliError.noStream("视频提前结束")
            }
            active.removeAll { $0.0.end <= absolute }
            while cursor < timeline.cues.count && timeline.cues[cursor].start <= absolute {
                let cue = timeline.cues[cursor]
                if cue.end > absolute {
                    let sprite = try sprite(cue, timeline: timeline)
                    active.append((cue, sprite, try compositor.texture(sprite.image)))
                }
                cursor += 1
            }
            try autoreleasepool {
                var destination = buffer
                if adaptor != nil {
                    var fresh: CVPixelBuffer?
                    guard let pool = pixelPool,
                          CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &fresh) == kCVReturnSuccess,
                          let fresh else { throw BiliError.invalidInput("硬件编码帧缓冲分配失败") }
                    destination = fresh
                }
                let overlays = active.map { cue, sprite, texture in
                    let p = cue.position(at: absolute)
                    let x = p.x - (cue.centered ? sprite.width / 2 : 0) - sprite.padding
                    let y = p.y - sprite.padding
                    return (texture, x, y)
                }
                if adaptor != nil {
                    let command = try compositor.submit(input: imageBuffer, output: destination, overlays: overlays)
                    pending.append((command, destination, frame))
                    return
                }
                try compositor.render(input: imageBuffer, output: destination, overlays: overlays)
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw BiliError.invalidInput("GPU 帧不可读") }
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                if stride == width * 4 {
                    try pipe.fileHandleForWriting.write(contentsOf: Data(bytesNoCopy: base, count: stride * height, deallocator: .none))
                } else {
                    for row in 0..<height {
                        try pipe.fileHandleForWriting.write(contentsOf: Data(bytesNoCopy: base.advanced(by: row * stride), count: width * 4, deallocator: .none))
                    }
                }
            }
            if hardware && pending.count >= 3 { try await appendOldest() }
            if frame % 30 == 0 || frame == frames - 1 {
                let t = Double(hardware ? submittedFrames : frame + 1) / fps
                progress(FFProgress(fraction: min(1, t / duration), speed: t / max(watch.elapsed, 0.001),
                                    fps: Double(frame + 1) / max(watch.elapsed, 0.001), outTime: t))
            }
            if hardware && watch.elapsed - lastReport >= 15 {
                let count = max(1, submittedFrames)
                Log.info(String(format: "Metal 流水线：%.2fx，已提交 %d 帧；GPU等待 %.3fms/帧，编码背压 %.3fms/帧，提交 %.3fms/帧（累计）",
                    Double(count) / fps / watch.elapsed, count, gpuWait * 1000 / Double(count),
                    writerWait * 1000 / Double(count), appendTime * 1000 / Double(count)), tag: tag)
                lastReport = watch.elapsed
            }
        }
        if let writer, let writerInput {
            while !pending.isEmpty { try await appendOldest() }
            progress(FFProgress(fraction: 1, speed: duration / max(watch.elapsed, 0.001),
                fps: Double(frames) / max(watch.elapsed, 0.001), outTime: duration))
            writerInput.markAsFinished()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                writer.finishWriting { c.resume() }
            }
            try Task.checkCancellation()
            guard writer.status == .completed else { throw writer.error ?? BiliError.ffmpegFailed("硬件编码未完成") }
            try? FileManager.default.removeItem(at: logURL)
            return
        }
        try pipe.fileHandleForWriting.close()
        process.waitUntilExit()
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            let message = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "编码失败"
            throw BiliError.ffmpegFailed(String(message.suffix(2000)))
        }
        try? FileManager.default.removeItem(at: logURL)
    }
}
