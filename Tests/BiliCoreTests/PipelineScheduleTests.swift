import XCTest
@testable import BiliCore

final class PipelineScheduleTests: XCTestCase {
    func testNextJobCannotOvertakeFirstJobBeforeDownloadAdmission() {
        XCTAssertTrue(PipelineSchedule.canSubmitNext(activeDownloadStarted: []))
        // 第一项尚在解析信息/等待 Task 调度时，禁止提交第二项抢占通道。
        XCTAssertFalse(PipelineSchedule.canSubmitNext(activeDownloadStarted: [false]))
        XCTAssertTrue(PipelineSchedule.canSubmitNext(activeDownloadStarted: [true]))
        XCTAssertFalse(PipelineSchedule.canSubmitNext(activeDownloadStarted: [true, false]))
        XCTAssertFalse(PipelineSchedule.canSubmitNext(activeDownloadStarted: [true, true]))
    }

    func testDownloadOverlapsCompositionAndOnlyOneVideoIsPrefetched() async throws {
        let schedule = PipelineSchedule()
        let first = try await schedule.begin()
        try await first.compose()
        // 第一项合成期间，第二项可以下载。
        let second = try await schedule.begin()
        let secondComposed = expectation(description: "第二项获得合成名额")
        let composeTask = Task {
            try await second.compose()
            secondComposed.fulfill()
        }
        let thirdDownloaded = expectation(description: "第三项获得下载名额")
        let thirdTask = Task {
            let third = try await schedule.begin()
            thirdDownloaded.fulfill()
            return third
        }
        // 第一项完成后，第二项进入合成，第三项才开始下载。
        await first.finish()
        try await composeTask.value
        await fulfillment(of: [secondComposed, thirdDownloaded], timeout: 2)
        let third = try await thirdTask.value
        await second.finish()
        try await third.compose()
        await third.finish()
    }

    func testCancelledWaiterDoesNotLeakDownloadSlot() async throws {
        let schedule = PipelineSchedule()
        let first = try await schedule.begin()
        let pending = Task { try await schedule.begin() }
        pending.cancel()
        do {
            _ = try await pending.value
            XCTFail("取消的下载等待应当结束")
        } catch is CancellationError {} catch { XCTFail("意外错误：\(error)") }
        await first.finish()
        let next = try await schedule.begin()
        await next.finish()
    }
}
