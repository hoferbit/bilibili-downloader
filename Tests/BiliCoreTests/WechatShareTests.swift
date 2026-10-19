import XCTest
@testable import BiliCore

final class WechatShareTests: XCTestCase {
    private func client(in root: URL) -> BiliClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CachedStreamStub.self]
        let client = BiliClient(store: CookieStore(fileURL: root.appendingPathComponent("cookies.json")), configuration: configuration)
        client.setCookies(["buvid3": "test-only-placeholder"])
        return client
    }

    func testLegacyProcessingOptionsAreIgnored() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"wechatShareEnabled":true,"wechatShareSpeed":1.5,"wechatShareVideoKbps":1000,"wechatShareMaxDimension":960}"#.utf8))
        XCTAssertTrue(settings.wechatShareEnabled)
        let encoded = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        XCTAssertFalse(encoded.contains("wechatShareSpeed"))
        XCTAssertFalse(encoded.contains("wechatShareVideoKbps"))
        XCTAssertFalse(encoded.contains("wechatShareMaxDimension"))
    }

    func testOriginalIsCopiedByteForByteWithoutRunningEncoder() async throws {
        guard let ffmpeg = FFmpeg.locate() else { throw XCTSkip("需要 ffmpeg 生成测试素材") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = AppSettings()
        settings.downloadDir = root.path
        settings.wechatShareEnabled = true
        settings.danmakuMode = .burn
        settings.burn60fps = true
        settings.saveXML = true
        settings.autoRetry = 0
        let entry = VideoEntry(aid: 1, bvid: "", cid: 1, title: "原片标题", fileName: "ignored filename", folder: "ignored folder")
        let cache = settings.workLayout.cacheDirectory(for: entry)
        let working = cache.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        let original = cache.appendingPathComponent("原片标题.mp4")
        try await ffmpeg.run(["-f", "lavfi", "-i", "testsrc2=s=640x360:r=25:d=3",
                              "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
                              "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-shortest", original.path])
        let bytes = try Data(contentsOf: original)
        try CachedStreamStub.stream.cacheIdentity.write(to: working.appendingPathComponent("source.key"), atomically: true, encoding: .utf8)
        let final = root.appendingPathComponent("原片标题.mp4")
        let previous = Data("test-only-previous-processed-output".utf8)
        try previous.write(to: final)
        try "unused ASS".write(to: cache.appendingPathComponent("danmaku.ass"), atomically: true, encoding: .utf8)
        let client = client(in: root)
        defer { client.session.invalidateAndCancel() }
        // 若分享路径尝试编码、转速、改帧率或渲染弹幕，false 会令测试立即失败。
        let pipeline = DownloadPipeline(client: client, settings: settings, ffmpeg: FFmpeg(path: "/usr/bin/false"))
        let result = try await pipeline.run(entry) { _ in }
        XCTAssertEqual(result.file, final)
        XCTAssertEqual(try Data(contentsOf: final), bytes)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("previous-") })
        XCTAssertEqual(try Data(contentsOf: backup), previous)
        let repeated = try await pipeline.run(entry) { _ in }
        XCTAssertTrue(repeated.skipped)
        XCTAssertEqual(repeated.file, final)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("danmaku.xml").path))
    }

    func testSelectsLowestResolutionThenLowestKnownBitrates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = client(in: root)
        defer { client.session.invalidateAndCancel() }
        let stream = try await client.streams(for: VideoEntry(aid: 2, bvid: "", cid: 1, title: "test"),
                                              quality: 16, codec: .avc, prefer60: false,
                                              requestedQuality: 16, preferSmallest: true)
        XCTAssertEqual(stream.qn, 16)
        XCTAssertEqual(stream.codec, .hevc)
        XCTAssertEqual(stream.videoBandwidth, 500)
        XCTAssertEqual(stream.audioId, 2)
        XCTAssertEqual(stream.audioURLs, ["https://example.invalid/low.m4s"])
        let unavailable = try await client.streams(for: VideoEntry(aid: 999, bvid: "", cid: 1, title: "test"),
                                                   quality: 16, codec: .avc, prefer60: false,
                                                   requestedQuality: 16, preferSmallest: true)
        XCTAssertEqual(unavailable.qn, 80)
    }
}
