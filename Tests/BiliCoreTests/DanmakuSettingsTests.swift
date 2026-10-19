import XCTest
@testable import BiliCore

final class DanmakuSettingsTests: XCTestCase {
    func testDefaultGPUPipeline() {
        let settings = AppSettings()
        XCTAssertEqual(settings.danmakuRenderer, .metal)
        XCTAssertEqual(settings.burnEncoder, .h264)
        XCTAssertEqual(settings.hardwareBitrateKbps, 3000)
        XCTAssertEqual(settings.burnSegments, 0)
        XCTAssertTrue(settings.burn60fps)
    }

    func testScreenshotPreset() {
        let style = DanmakuStyle()
        XCTAssertEqual(style.displayArea, 0.25)
        XCTAssertEqual(style.opacity, 0.95)
        XCTAssertEqual(style.fontScale, 1.7)
        XCTAssertFalse(style.heavyOutline)
        XCTAssertEqual(style.fontName, "得意黑")
        XCTAssertEqual(style.outlineOpacity, 0.85)
        let ass = DanmakuASS.make([], width: 1920, height: 1080, style: style).text
        XCTAssertTrue(ass.contains("&H26000000"))
        XCTAssertTrue(ass.contains(",1,1.9,0,7,"))
    }

    func testLegacyMigrationAndCustomSettingsRoundTrip() throws {
        let legacy = Data(#"{"quality":64,"danmakuStyle":{"fontScale":1,"displayArea":1}}"#.utf8)
        let migrated = try JSONDecoder().decode(AppSettings.self, from: legacy)
        XCTAssertEqual(migrated.quality, 64)
        XCTAssertEqual(migrated.danmakuStyle.fontScale, 1.7)
        var custom = migrated
        custom.danmakuStyle.fontScale = 1.2
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(custom))
        XCTAssertEqual(restored.danmakuStyle.fontScale, 1.2)
    }
}
