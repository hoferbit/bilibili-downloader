import XCTest
@testable import BiliCore

final class DanmakuControlCharacterTests: XCTestCase {
    private func comment(_ time: Double, _ text: String) -> DanmakuComment {
        DanmakuComment(id: Int64(time * 1000), time: time, mode: 5, fontSize: 25,
                       color: 0xFFFFFF, midHash: "", content: text, ctime: 0, weight: 0, pool: 0)
    }

    func testNULDoesNotTruncateLaterDanmakuInLibass() throws {
        // 安徽实测的异常内容；后续事件必须仍能被真实 libass 读入。
        let result = DanmakuASS.make([
            comment(0, "before"), comment(414.588, "过\0AUTH劲"), comment(2700, "after")
        ], width: 320, height: 180, style: DanmakuStyle())
        XCTAssertEqual(result.count, 3)
        XCTAssertFalse(result.text.contains("\0"))
        XCTAssertTrue(result.text.contains("过AUTH劲"))
        guard let ffmpeg = FFmpeg.locate() else { throw XCTSkip("需要 ffmpeg/libass") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try result.text.write(to: dir.appendingPathComponent("test.ass"), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg.path)
        process.currentDirectoryURL = dir
        process.arguments = ["-hide_banner", "-f", "lavfi", "-i", "color=black:s=320x180:d=0.04",
                             "-vf", "ass=test.ass", "-f", "null", "-"]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, log)
        XCTAssertTrue(log.contains("3 events)"), log)
    }

    func testControlOnlyCommentsDoNotOccupyLanesAndLineBreaksSurvive() {
        let result = DanmakuASS.make([
            comment(0, "\0\u{01}\u{1B}\u{7F}\u{85}"), comment(0, "第一行\r\n第二行\t文字👩‍🚀")
        ], width: 1920, height: 1080, style: DanmakuStyle())
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.filtered, 1)
        XCTAssertEqual(result.dropped, 0)
        XCTAssertTrue(result.text.contains("第一行\\N第二行\t文字👩‍🚀"))
    }
}
