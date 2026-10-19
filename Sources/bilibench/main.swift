import BiliCore
import Foundation

// 离线基准工具：不联网、不修改登录信息或 App 设置。
// bilibench input.mp4 timeline.ass output-dir libass|metal x264|h264|hevc segments duration [hardware-kbps]
let a = CommandLine.arguments
guard a.count == 8 || a.count == 9 else {
    print("bilibench input.mp4 timeline.ass output-dir libass|metal x264|h264|hevc segments duration")
    exit(1)
}
let input = URL(fileURLWithPath: a[1])
let work = URL(fileURLWithPath: a[3], isDirectory: true)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
let ass = work.appendingPathComponent("danmaku.ass")
if ass.path != URL(fileURLWithPath: a[2]).path {
    try? FileManager.default.removeItem(at: ass)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: a[2]), to: ass)
}
let ff = FFmpeg.locate()!
let (w, h, fps) = await ff.probeSize(input)!
let duration = Double(a[7])!
let renderer = DanmakuRenderer(rawValue: a[4]) ?? .metal
let encoder = BurnEncoder(rawValue: a[5])!
let watch = Stopwatch()
let bitrate = a.count == 9 ? Int(a[8]) : nil
if a[4] == "hybrid" {
    let split = (duration / 4).rounded()
    let cpu = work.appendingPathComponent("cpu.mp4")
    let gpu = work.appendingPathComponent("gpu.mp4")
    let fonts = work.appendingPathComponent("ass-fonts")
    try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
    let sourceFont = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts/SmileySans-Oblique.ttf")
    let font = fonts.appendingPathComponent(sourceFont.lastPathComponent)
    if !FileManager.default.fileExists(atPath: font.path) { try FileManager.default.copyItem(at: sourceFont, to: font) }
    async let c: Void = MetalDanmaku.segment(ffmpeg: ff, input: input, ass: ass, output: cpu,
        start: 0, duration: split, fps: 60,
        encoder: ["-c:v", "libx264", "-preset", "medium", "-crf", "26", "-threads", "6", "-video_track_timescale", "600"],
        tag: "hybrid-cpu") { _ in }
    async let g: Void = MetalDanmaku.segment(ffmpeg: ff, input: input, ass: ass, output: gpu,
        start: split, duration: duration-split, fps: 60,
        encoder: ["-c:v", "h264_videotoolbox", "-b:v", "3000k"], tag: "hybrid-bench") { _ in }
    _ = try await (c, g)
    try await ff.concat([cpu, gpu], output: work.appendingPathComponent("output.mp4"), workDir: work)
} else {
try await ff.burn(input: input, assName: "danmaku.ass", workDir: work,
                  output: work.appendingPathComponent("output.mp4"), width: w, height: h,
                  fps60: true, sourceFPS: fps, encoder: encoder, quality: .size,
                  duration: duration, segments: Int(a[6])!, renderer: renderer, hardwareBitrateKbps: bitrate, tag: "benchmark") { _, _ in }
}
print(String(format: "%@ %@ wall=%.3fs speed=%.3fx", a[4], a[5], watch.elapsed, duration / watch.elapsed))
Log.shared.flush()
