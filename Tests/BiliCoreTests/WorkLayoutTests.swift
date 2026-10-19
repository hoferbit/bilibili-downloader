import XCTest
@testable import BiliCore

final class CachedStreamStub: URLProtocol {
    static var stream: StreamInfo {
        StreamInfo(videoURLs: ["https://example.invalid/video.m4s"], audioURLs: nil, qn: 16, codec: .avc,
                   width: 640, height: 360, fps: 25, videoBandwidth: 1000, durationMs: 2000, available: [16])
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let payload: [String: Any]
        if request.url?.path == "/x/web-interface/nav" {
            payload = ["code": 0, "data": ["wbi_img": ["img_url": "https://example.invalid/" + String(repeating: "a", count: 32) + ".png",
                                                       "sub_url": "https://example.invalid/" + String(repeating: "b", count: 32) + ".png"]]]
        } else if request.url?.path == "/x/player/wbi/playurl" {
            let params = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let share = params.contains { $0.name == "qn" && $0.value == "16" }
                && !params.contains { $0.name == "avid" && $0.value == "999" }
            let qn = share ? 16 : 80
            let lowestCodec = params.contains { $0.name == "avid" && $0.value == "2" }
            var video: [[String: Any]] = [["id": qn, "codecid": 7, "base_url": "https://example.invalid/video.m4s",
                                           "width": share ? 640 : 320, "height": share ? 360 : 180,
                                           "frame_rate": share ? "25" : "30", "bandwidth": 1000]]
            var audio: [[String: Any]] = []
            if share {
                video += [
                    ["id": 16, "codecid": 12, "base_url": "https://example.invalid/hevc.m4s", "width": 640, "height": 360, "bandwidth": lowestCodec ? 500 : 1500],
                    ["id": 16, "codecid": 13, "base_url": "https://example.invalid/unknown.m4s", "width": 640, "height": 360, "bandwidth": 0],
                    ["id": 32, "codecid": 7, "base_url": "https://example.invalid/480p.m4s", "width": 854, "height": 480, "bandwidth": 300],
                    ["id": 16, "codecid": 7, "base_url": "https://example.invalid/encrypted.m4s", "width": 640, "height": 360, "bandwidth": 1, "drm_tech_type": 1]
                ]
                if lowestCodec {
                    audio = [["id": 1, "base_url": "https://example.invalid/high.m4s", "bandwidth": 128000],
                             ["id": 2, "base_url": "https://example.invalid/low.m4s", "bandwidth": 64000],
                             ["id": 3, "base_url": "https://example.invalid/unknown-audio.m4s", "bandwidth": 0]]
                }
            }
            payload = ["code": 0, "data": ["timelength": 2000, "accept_quality": [qn], "dash": ["video": video, "audio": audio]]]

        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class WorkLayoutTests: XCTestCase {
    func testDefaultMigrationAndExplicitWorkDirectory() throws {
        XCTAssertEqual(AppSettings().workLayout.root, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/bilibili-downloader", isDirectory: true))
        let old = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Bilibili").path
        let migrated = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: ["downloadDir": old]))
        XCTAssertEqual(migrated.workLayout.root, WorkLayout.defaultDirectory)
        let explicit = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"downloadDir":"/tmp/custom-work"}"#.utf8))
        XCTAssertEqual(explicit.workLayout.root.path, "/tmp/custom-work")
        let entry = VideoEntry(aid: 1, bvid: "", cid: 2, title: "P01", folder: "series")
        let layout = WorkLayout(directory: "/tmp/custom-work")
        XCTAssertEqual(layout.cacheDirectory(for: entry).deletingLastPathComponent(), layout.cache)
        XCTAssertEqual(layout.outputName(for: entry), "P01")
        let folder = layout.cacheDirectory(for: entry).lastPathComponent
        XCTAssertNotNil(folder.range(of: #"^\d{8} P01$"#, options: .regularExpression))
    }

    func testOriginalSurvivesAndCollectionOutputIsFlat() async throws {
        guard let ffmpeg = FFmpeg.locate() else { throw XCTSkip("需要 ffmpeg") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = AppSettings()
        settings.downloadDir = root.path
        settings.danmakuMode = .none
        settings.autoRetry = 0
        let layout = settings.workLayout
        try layout.prepare()
        let entry = VideoEntry(aid: 1, bvid: "", cid: 2, title: "P01", folder: "series")
        let cache = layout.cacheDirectory(for: entry).appendingPathComponent("normal", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let original = cache.appendingPathComponent("merged.mp4")
        try await ffmpeg.run(["-f", "lavfi", "-i", "color=black:s=320x180:r=30:d=2", "-c:v", "libx264", original.path])
        let stream = StreamInfo(videoURLs: ["https://example.invalid/video.m4s"], audioURLs: nil, qn: 80, codec: .avc,
                                width: 320, height: 180, fps: 30, videoBandwidth: 1000, durationMs: 2000, available: [80])
        try stream.cacheIdentity.write(to: cache.appendingPathComponent("source.key"), atomically: true, encoding: .utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CachedStreamStub.self]
        let client = BiliClient(store: CookieStore(fileURL: root.appendingPathComponent("cookies.json")), configuration: configuration)
        defer { client.session.invalidateAndCancel() }
        client.setCookies(["buvid3": "test-only-placeholder"])
        let result = try await DownloadPipeline(client: client, settings: settings, ffmpeg: ffmpeg).run(entry) { _ in }
        XCTAssertEqual(result.file, root.appendingPathComponent("P01.mp4"))
        XCTAssertEqual(try Data(contentsOf: result.file), try Data(contentsOf: original))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.logs.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("series").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".bilidl-tmp").path))
    }

    func testLogSwitchesDirectoryAndFlushesPreviousFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        let log = Log(workDirectory: first)
        log.write(.info, "first-test-message")
        log.flush()
        let firstFile = log.currentFile
        XCTAssertEqual(firstFile.deletingLastPathComponent(), first.appendingPathComponent("01_log", isDirectory: true))
        log.configureDirectory(workDirectory: second)
        log.write(.info, "second-test-message")
        log.flush()
        XCTAssertTrue(try String(contentsOf: firstFile, encoding: .utf8).contains("first-test-message"))
        let secondText = try String(contentsOf: log.currentFile, encoding: .utf8)
        XCTAssertTrue(secondText.contains("second-test-message"))
        XCTAssertFalse(secondText.contains("first-test-message"))
    }
}
