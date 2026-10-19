import XCTest
@testable import BiliCore

final class WechatShareTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func capture(_ executable: String, _ args: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return data
    }

    private func metadata(_ ffmpeg: FFmpeg, _ input: URL) throws -> JSON {
        let probe = URL(fileURLWithPath: ffmpeg.path).deletingLastPathComponent().appendingPathComponent("ffprobe")
        return try JSON(data: capture(probe.path, ["-v", "error", "-show_streams", "-show_format", "-of", "json", input.path]))
    }

    func testDefaultsLegacySettingsRoundTripAndSafeOutputNames() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(settings.wechatShareEnabled)
        XCTAssertEqual(settings.wechatShareOptions, WechatShareOptions())
        XCTAssertEqual(settings.wechatShareSpeed, 1.5)
        var changed = settings
        changed.wechatShareEnabled = true
        changed.wechatShareSpeed = 1.75
        changed.wechatShareVideoKbps = 800
        changed.wechatShareMaxDimension = 640
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(changed)), changed)
        let input = URL(fileURLWithPath: "/tmp/" + String(repeating: "长文件名", count: 30) + ".mp4")
        let output = WechatShareOptions().outputURL(for: input)
        XCTAssertNotEqual(output, input)
        XCTAssertLessThanOrEqual(output.lastPathComponent.utf8.count, 255)
        XCTAssertTrue(output.lastPathComponent.contains("微信分享 1.5倍"))
        XCTAssertNotEqual(changed.wechatShareOptions.outputURL(for: input), output)
        let invalid = WechatShareOptions(speed: .infinity, videoKbps: -1, maxDimension: 99999)
        XCTAssertEqual(invalid.speed, 1.5)
        XCTAssertEqual(invalid.videoKbps, 400)
        XCTAssertEqual(invalid.maxDimension, 1280)
    }

    func testRealExportPreservesPitchAndTargetsDurationDimensionsAndSize() async throws {
        guard let ffmpeg = FFmpeg.locate() else { throw XCTSkip("需要 ffmpeg") }
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("source.mp4")
        try await ffmpeg.run(["-f", "lavfi", "-i", "testsrc2=s=1280x720:r=30:d=9",
                              "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=9",
                              "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-shortest", input.path])
        let options = WechatShareOptions()
        let output = options.outputURL(for: input)
        try await ffmpeg.exportWechatShare(input: input, output: output, options: options, sourceDuration: 9)
        let result = try metadata(ffmpeg, output)
        let video = try XCTUnwrap(result["streams"].array.first { $0["codec_type"].string == "video" })
        XCTAssertEqual(video["codec_name"].string, "h264")
        XCTAssertEqual(video["pix_fmt"].string, "yuv420p")
        XCTAssertEqual(video["width"].int, 960)
        XCTAssertEqual(video["height"].int, 540)
        XCTAssertEqual(video["r_frame_rate"].string, "30/1")
        let duration = try XCTUnwrap(Double(result["format"]["duration"].string ?? ""))
        XCTAssertEqual(duration, 6, accuracy: 0.15)
        let targetBytes = 6.0 * 1064 * 1000 / 8
        XCTAssertEqual(Double(fileSize(output)), targetBytes, accuracy: targetBytes * 0.25)
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
        // 音频 440Hz 测试音加速后仍须接近 440Hz，不能变成 660Hz。
        let pcm = try capture(ffmpeg.path, ["-v", "error", "-ss", "1", "-i", output.path, "-t", "2",
                                            "-vn", "-ac", "1", "-ar", "8000", "-f", "s16le", "pipe:1"])
        let bytes = [UInt8](pcm)
        let samples = stride(from: 0, to: bytes.count - 1, by: 2).map { Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8) }
        let crossings = zip(samples, samples.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
        XCTAssertEqual(Double(crossings) / (Double(samples.count) / 8000), 440, accuracy: 5)
    }

    func testExistingSilentPortraitIsReusedWithoutDownloadAndCanBeSkipped() async throws {
        guard let ffmpeg = FFmpeg.locate() else { throw XCTSkip("需要 ffmpeg") }
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("portrait.mp4")
        try await ffmpeg.run(["-f", "lavfi", "-i", "testsrc2=s=360x640:r=24:d=3",
                              "-c:v", "libx264", "-preset", "ultrafast", input.path])
        let client = BiliClient(store: CookieStore(fileURL: dir.appendingPathComponent("unused-cookies.json")))
        defer { client.session.invalidateAndCancel() }
        var settings = AppSettings()
        settings.downloadDir = dir.path
        settings.danmakuMode = .none
        settings.wechatShareEnabled = true
        settings.autoRetry = 0
        let pipeline = DownloadPipeline(client: client, settings: settings, ffmpeg: ffmpeg)
        let entry = VideoEntry(aid: 1, bvid: "", cid: 1, title: "portrait")
        let first = try await pipeline.run(entry) { _ in }
        XCTAssertFalse(first.skipped)
        XCTAssertNotEqual(first.file, input)
        let probed = await ffmpeg.probeSize(first.file)
        let size = try XCTUnwrap(probed)
        XCTAssertEqual(size.0, 360)
        XCTAssertEqual(size.1, 640)
        let duration = await ffmpeg.probeDuration(first.file)
        XCTAssertEqual(try XCTUnwrap(duration), 2, accuracy: 0.15)
        let second = try await pipeline.run(entry) { _ in }
        XCTAssertTrue(second.skipped)
        XCTAssertEqual(first.file, second.file)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix(".wechat-") })
    }

    func testSidecarIsBurnedBeforeSpeedChange() async throws {
        guard let ffmpeg = FFmpeg.locate() else { throw XCTSkip("需要 ffmpeg/libass") }
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("black.mp4")
        try await ffmpeg.run(["-f", "lavfi", "-i", "color=black:s=640x360:r=30:d=6",
                              "-c:v", "libx264", "-preset", "ultrafast", input.path])
        var style = DanmakuStyle()
        style.fontName = "Hiragino Sans GB"
        style.fixedDuration = 1.5
        let comment = DanmakuComment(id: 1, time: 3, mode: 5, fontSize: 25, color: 0xFFFFFF,
                                     midHash: "", content: "SHARE", ctime: 0, weight: 0, pool: 0)
        let ass = dir.appendingPathComponent("black.ass")
        try DanmakuASS.make([comment], width: 640, height: 360, style: style).text.write(to: ass, atomically: true, encoding: .utf8)
        let output = WechatShareOptions().outputURL(for: input)
        try await ffmpeg.exportWechatShare(input: input, output: output, options: WechatShareOptions(), ass: ass, sourceDuration: 6)
        // 原片第 3~4.5 秒的弹幕应出现在分享版第 2~3 秒。
        func brightPixels(at time: String) throws -> Int {
            let data = try capture(ffmpeg.path, ["-v", "error", "-ss", time, "-i", output.path, "-frames:v", "1", "-pix_fmt", "gray", "-f", "rawvideo", "pipe:1"])
            return data.filter { $0 > 100 }.count
        }
        XCTAssertEqual(try brightPixels(at: "1"), 0)
        XCTAssertGreaterThan(try brightPixels(at: "2.5"), 50)
        XCTAssertEqual(try brightPixels(at: "3.5"), 0)
    }

    func testExportFailureAndCancellationPreserveOriginalAndCleanTemporaryFiles() async throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("original.mp4")
        let original = Data("test-only-original-placeholder".utf8)
        try original.write(to: input)
        let output = WechatShareOptions().outputURL(for: input)
        let failing = FFmpeg(path: "/usr/bin/false")
        do {
            try await failing.exportWechatShare(input: input, output: output, options: WechatShareOptions())
            XCTFail("编码失败须向队列报告错误")
        } catch { XCTAssertTrue(error is BiliError) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await failing.exportWechatShare(input: input, output: output, options: WechatShareOptions())
        }
        do {
            try await cancelled.value
            XCTFail("已取消的任务不能继续导出")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["original.mp4"])
    }
}
