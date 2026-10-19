import CoreGraphics
import CoreVideo
import Metal
import XCTest
@testable import BiliCore

final class MetalCompositorTests: XCTestCase {
    func testNV12ConversionAndOverlayOnActualGPU() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("无 Metal 设备") }
        func buffer(_ format: OSType) throws -> CVPixelBuffer {
            var b: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, format,
                [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary, &b)
            XCTAssertEqual(status, kCVReturnSuccess)
            return try XCTUnwrap(b)
        }
        let source = try buffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let target = try buffer(kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(source, [])
        for plane in 0..<2 {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(source, plane))
            memset(base, 128, CVPixelBufferGetBytesPerRowOfPlane(source, plane) * CVPixelBufferGetHeightOfPlane(source, plane))
        }
        CVPixelBufferUnlockBaseAddress(source, [])
        let compositor = try MetalCompositor(device: device, width: 16, height: 16)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let texture = try compositor.texture(XCTUnwrap(ctx.makeImage()))
        try compositor.render(input: source, output: target, overlays: [(texture, 4, 4)])
        CVPixelBufferLockBaseAddress(target, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(target, .readOnly) }
        let ptr = try XCTUnwrap(CVPixelBufferGetBaseAddress(target)).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(Int(ptr[0]), 130, accuracy: 2)
        XCTAssertEqual(ptr[0], ptr[1])
        XCTAssertEqual(ptr[1], ptr[2])
        let pixel = 5 * CVPixelBufferGetBytesPerRow(target) + 5 * 4
        XCTAssertGreaterThan(ptr[pixel+2], 250)
        XCTAssertLessThan(ptr[pixel], 3)
        XCTAssertLessThan(ptr[pixel+1], 3)

        // Encoder-facing NV12 planes: neutral background and red overlay in BT.709 limited range.
        let nv12 = try buffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        try compositor.render(input: source, output: nv12, overlays: [(texture, 4, 4)])
        CVPixelBufferLockBaseAddress(nv12, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(nv12, .readOnly) }
        let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(nv12, 0)).assumingMemoryBound(to: UInt8.self)
        let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(nv12, 1)).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(Int(luma[0]), 128, accuracy: 1)
        XCTAssertEqual(Int(chroma[0]), 128, accuracy: 1)
        XCTAssertEqual(Int(chroma[1]), 128, accuracy: 1)
        XCTAssertEqual(Int(luma[5 * CVPixelBufferGetBytesPerRowOfPlane(nv12, 0) + 5]), 63, accuracy: 1)
        let c = 2 * CVPixelBufferGetBytesPerRowOfPlane(nv12, 1) + 4
        XCTAssertEqual(Int(chroma[c]), 102, accuracy: 1)
        XCTAssertEqual(Int(chroma[c+1]), 240, accuracy: 1)
    }
}
