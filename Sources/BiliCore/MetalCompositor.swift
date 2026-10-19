import CoreVideo
import Metal
import Foundation

/// 单次 render pass：NV12 视频转换为 BT.709 RGB，叠加预乘 alpha 弹幕纹理。
final class MetalCompositor {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let videoPipeline: MTLRenderPipelineState
    private let textPipeline: MTLRenderPipelineState
    private let nv12Pipeline: MTLComputePipelineState
    private var cache: CVMetalTextureCache?
    private let width: Int, height: Int

    init(device: MTLDevice, width: Int, height: Int) throws {
        self.device = device
        self.width = width
        self.height = height
        guard let queue = device.makeCommandQueue() else { throw BiliError.invalidInput("无法创建 Metal 队列") }
        commandQueue = queue
        let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct Vertex { float2 position; float2 uv; };
        struct VOut { float4 position [[position]]; float2 uv; };
        vertex VOut vmain(uint id [[vertex_id]], constant Vertex *vertices [[buffer(0)]]) {
            VOut v; v.position = float4(vertices[id].position, 0, 1); v.uv = vertices[id].uv; return v;
        }
        fragment float4 video(VOut v [[stage_in]], texture2d<float> y [[texture(0)]], texture2d<float> uv [[texture(1)]]) {
            constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
            float l = (y.sample(s,v.uv).r - 16.0/255.0) * (255.0/219.0);
            float2 c = (uv.sample(s,v.uv).rg - float2(128.0/255.0)) * (255.0/224.0);
            float3 rgb = float3(l+1.5748*c.y, l-0.187324*c.x-0.468124*c.y, l+1.8556*c.x);
            return float4(clamp(rgb,0.0,1.0),1);
        }
        fragment float4 text(VOut v [[stage_in]], texture2d<float> t [[texture(0)]]) {
            constexpr sampler s(coord::normalized, address::clamp_to_zero, filter::linear);
            return t.sample(s,v.uv);
        }
        // One thread per 2x2 block: limited-range BT.709, average chroma before quantizing.
        kernel void packNV12(texture2d<float, access::read> rgb [[texture(0)]],
                             texture2d<float, access::write> y [[texture(1)]],
                             texture2d<float, access::write> uv [[texture(2)]],
                             uint2 p [[thread_position_in_grid]]) {
            if (p.x >= uv.get_width() || p.y >= uv.get_height()) return;
            float2 chroma = 0;
            for (uint j=0; j<2; ++j) for (uint i=0; i<2; ++i) {
                uint2 q = p*2 + uint2(i,j);
                float3 c = rgb.read(q).rgb;
                float l = dot(c, float3(0.2126,0.7152,0.0722));
                y.write(float4((16.0+219.0*l)/255.0,0,0,1),q);
                chroma += float2((c.b-l)/1.8556,(c.r-l)/1.5748);
            }
            uv.write(float4((128.0+224.0*chroma/4.0)/255.0,0,1),p);
        }
        """
        let library = try device.makeLibrary(source: shader, options: nil)
        func pipeline(_ name: String, blend: Bool) throws -> MTLRenderPipelineState {
            let p = MTLRenderPipelineDescriptor()
            p.vertexFunction = library.makeFunction(name: "vmain")
            p.fragmentFunction = library.makeFunction(name: name)
            p.colorAttachments[0].pixelFormat = .bgra8Unorm
            if blend {
                let a = p.colorAttachments[0]!
                a.isBlendingEnabled = true
                a.sourceRGBBlendFactor = .one
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.sourceAlphaBlendFactor = .one
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: p)
        }
        videoPipeline = try pipeline("video", blend: false)
        textPipeline = try pipeline("text", blend: true)
        nv12Pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "packNV12")!)
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess else {
            throw BiliError.invalidInput("无法创建 Metal 视频纹理缓存")
        }
    }

    func texture(_ image: CGImage) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: image.width, height: image.height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor), let provider = image.dataProvider,
              let data = provider.data, let bytes = CFDataGetBytePtr(data) else {
            throw BiliError.invalidInput("无法上传弹幕纹理")
        }
        texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                        withBytes: bytes, bytesPerRow: image.bytesPerRow)
        return texture
    }

    private func cvTexture(_ buffer: CVPixelBuffer, format: MTLPixelFormat, width: Int, height: Int, plane: Int) throws -> (CVMetalTexture, MTLTexture) {
        var ref: CVMetalTexture?
        guard let cache, CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil, format,
                                                                 width, height, plane, &ref) == kCVReturnSuccess,
              let ref, let texture = CVMetalTextureGetTexture(ref) else { throw BiliError.invalidInput("无法读取 GPU 视频纹理") }
        return (ref, texture)
    }

    private func vertices(x: Double, y: Double, w: Double, h: Double) -> [Float] {
        let l = Float(x / Double(width) * 2 - 1), r = Float((x+w) / Double(width) * 2 - 1)
        let t = Float(1-y / Double(height) * 2), b = Float(1-(y+h) / Double(height) * 2)
        return [l,t,0,0, l,b,0,1, r,t,1,0, r,t,1,0, l,b,0,1, r,b,1,1]
    }

    func render(input: CVPixelBuffer, output: CVPixelBuffer, overlays: [(MTLTexture, Double, Double)]) throws {
        let command = try submit(input: input, output: output, overlays: overlays)
        command.waitUntilCompleted()
        if let error = command.error { throw error }
    }

    /// 资源保留到 GPU 真正完成；调用方最多保留三帧，避免无界积压。
    func submit(input: CVPixelBuffer, output: CVPixelBuffer, overlays: [(MTLTexture, Double, Double)]) throws -> MTLCommandBuffer {
        let (yr, y) = try cvTexture(input, format: .r8Unorm, width: width, height: height, plane: 0)
        let (ur, uv) = try cvTexture(input, format: .rg8Unorm, width: (width+1)/2, height: (height+1)/2, plane: 1)
        let nv12 = CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        var refs: [CVMetalTexture] = [yr, ur]
        var planes: (MTLTexture, MTLTexture)?
        let dst: MTLTexture
        if nv12 {
            guard width % 2 == 0, height % 2 == 0 else { throw BiliError.invalidInput("NV12 需要偶数画面尺寸") }
            let (lr, luma) = try cvTexture(output, format: .r8Unorm, width: width, height: height, plane: 0)
            let (cr, chroma) = try cvTexture(output, format: .rg8Unorm, width: width/2, height: height/2, plane: 1)
            refs += [lr, cr]
            planes = (luma, chroma)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead]
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw BiliError.invalidInput("无法创建 GPU 中间纹理") }
            dst = texture
        } else {
            let (dr, texture) = try cvTexture(output, format: .bgra8Unorm, width: width, height: height, plane: 0)
            refs.append(dr); dst = texture
        }
        guard let command = commandQueue.makeCommandBuffer() else { throw BiliError.invalidInput("无法提交 GPU 渲染") }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = dst
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw BiliError.invalidInput("无法创建 GPU 渲染通道") }
        func draw(_ vertices: [Float]) {
            vertices.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        encoder.setRenderPipelineState(videoPipeline)
        encoder.setFragmentTexture(y, index: 0)
        encoder.setFragmentTexture(uv, index: 1)
        draw(vertices(x: 0, y: 0, w: Double(width), h: Double(height)))
        encoder.setRenderPipelineState(textPipeline)
        for (texture, x, y) in overlays {
            encoder.setFragmentTexture(texture, index: 0)
            draw(vertices(x: x, y: y, w: Double(texture.width), h: Double(texture.height)))
        }
        encoder.endEncoding()
        if let (luma, chroma) = planes {
            guard let compute = command.makeComputeCommandEncoder() else { throw BiliError.invalidInput("无法创建 NV12 转换通道") }
            compute.setComputePipelineState(nv12Pipeline)
            compute.setTexture(dst, index: 0)
            compute.setTexture(luma, index: 1)
            compute.setTexture(chroma, index: 2)
            compute.dispatchThreads(MTLSize(width: width/2, height: height/2, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            compute.endEncoding()
        }
        command.addCompletedHandler { _ in
            withExtendedLifetime((refs, input, output, dst)) {}
        }
        command.commit()
        return command
    }
}
