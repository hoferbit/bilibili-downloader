import XCTest
@testable import BiliCore

final class SystemUsageTests: XCTestCase {
    func testSamplingProducesBoundedValues() async throws {
        let probe = SystemUsageProbe()
        _ = await probe.sample()
        try await Task.sleep(nanoseconds: 100_000_000)
        let sample = await probe.sample()
        let cpu = try XCTUnwrap(sample.cpu)
        XCTAssertTrue((0...100).contains(cpu))
        if let gpu = sample.gpu { XCTAssertTrue((0...100).contains(gpu)) }
    }
}
