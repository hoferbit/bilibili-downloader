import BiliCore
import Foundation

let usage = """
用法: bilidl [选项] <链接或BV号>
       bilidl login | logout | whoami

支持：视频 / 多P / 合集 / 系列 / 收藏夹 / 番剧 / UP 主空间 / b23 短链

选项：
  -o, --output <目录>      工作目录（默认沿用 App 设置，初始为 ~/download/bilibili-downloader）
  -q, --quality <qn>       清晰度：120=4K 116=1080P60 112=1080P+ 80=1080P(默认) 64=720P 32=480P
  -c, --codec <avc|hevc|av1>   视频编码偏好（默认 avc）
  -d, --danmaku <none|ass|burn>  弹幕：不下载 / ASS 字幕 / 烧录进视频（默认 burn）
      --no-60fps           烧录弹幕时保持原帧率（默认输出 60fps）
  -e, --encoder <x264|h264|hevc>  烧录编码：软件 / H.264 硬件(默认) / H.265 硬件
  -s, --size <speed|balanced|size|smallest>  软件编码体积档位（默认 size：体积优先）
      --hardware-kbps <n>  硬件码率，单位 kbps（默认3000；0=自动）
      --renderer <libass|metal>  弹幕绘制方式（默认 metal）
      --segments <n>       烧录时并行渲染段数（默认 0 = 自动）
      --keep-original      兼容旧参数；原片现始终保留在 00_cache
      --xml                在 00_cache 中同时保存 XML 弹幕
      --wechat             下载最接近目标尺寸的源，生成无弹幕分享版（默认 1.5 倍速）
      --no-wechat          本次不生成微信分享版
      --wechat-speed <n>   分享倍速，1~2（默认 1.5）
      --wechat-kbps <n>    分享视频码率，400~2000（默认 1000）
      --wechat-edge <n>    分享最长边，320~1280 像素（默认 960）
      --all                列表全部下载（默认只下载链接指向的那一集/全部分P）
      --list               只列出解析结果，不下载
  -v, --verbose            在终端同时输出详细日志
  -j, --jobs <n>           兼容旧参数；现固定为下载一个＋合成一个
  -r, --retries <n>        临时错误自动重试次数（默认 2），已完成的步骤会复用
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    Log.error(msg)
    finish(1)
}

func finish(_ code: Int32) -> Never {
    Log.shared.flush()
    exit(code)
}

var args = Array(CommandLine.arguments.dropFirst())
var settings = AppSettings.load()
var selectAll = false
var listOnly = false
var target: String?

while !args.isEmpty {
    let a = args.removeFirst()
    func value() -> String {
        guard !args.isEmpty else { fail("\(a) 缺少参数") }
        return args.removeFirst()
    }
    switch a {
    case "-h", "--help": print(usage); exit(0)
    case "-o", "--output": settings.downloadDir = (value() as NSString).expandingTildeInPath
    case "-q", "--quality": settings.quality = Int(value()) ?? 80
    case "-c", "--codec": settings.codec = VideoCodec(rawValue: value()) ?? .avc
    case "-d", "--danmaku":
        switch value() {
        case "none": settings.danmakuMode = .none
        case "ass": settings.danmakuMode = .assFile
        default: settings.danmakuMode = .burn
        }
    case "--no-60fps": settings.burn60fps = false
    case "-e", "--encoder": settings.burnEncoder = BurnEncoder(rawValue: value()) ?? .x264
    case "-s", "--size": settings.burnQuality = BurnQuality(rawValue: value()) ?? .size
    case "--hardware-kbps": settings.hardwareBitrateKbps = max(0, Int(value()) ?? 0)
    case "--renderer": settings.danmakuRenderer = DanmakuRenderer(rawValue: value()) ?? .libass
    case "--segments": settings.burnSegments = max(0, Int(value()) ?? 0)
    case "--keep-original": settings.keepOriginal = true
    case "--xml": settings.saveXML = true
    case "--wechat": settings.wechatShareEnabled = true
    case "--no-wechat": settings.wechatShareEnabled = false
    case "--wechat-speed":
        guard let speed = Double(value()), speed.isFinite, (1 ... 2).contains(speed) else { fail("分享倍速须为 1~2") }
        settings.wechatShareSpeed = speed
    case "--wechat-kbps":
        guard let rate = Int(value()), (400 ... 2000).contains(rate) else { fail("分享视频码率须为 400~2000 kbps") }
        settings.wechatShareVideoKbps = rate
    case "--wechat-edge":
        guard let edge = Int(value()), (320 ... 1280).contains(edge) else { fail("分享最长边须为 320~1280 像素") }
        settings.wechatShareMaxDimension = edge
    case "--all": selectAll = true
    case "--list": listOnly = true
    case "-v", "--verbose":
        Log.shared.echo = { line in FileHandle.standardError.write(Data(("\r\u{1B}[2K" + line + "\n").utf8)) }
    case "-j", "--jobs": settings.concurrency = max(1, Int(value()) ?? 2)
    case "-r", "--retries": settings.autoRetry = max(0, Int(value()) ?? 2)
    default: target = a
    }
}

guard let target else { print(usage); exit(1) }
try settings.workLayout.prepare()
Log.configure(workDirectory: settings.workLayout.root)
let client = BiliClient()

func printProgress(_ line: String) {
    FileHandle.standardError.write(Data("\r\u{1B}[2K\(line)".utf8))
}

switch target {
case "login":
    let (url, key) = try await client.qrGenerate()
    print("请用哔哩哔哩 App 扫描二维码登录：\n")
    print(QRCode.terminal(url))
    var last = QRLoginState.waiting
    while true {
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let st = try await client.qrPoll(key: key)
        if st != last && st == .scanned { print("已扫码，请在手机上确认…") }
        last = st
        if st == .expired { fail("二维码已过期，请重新运行 bilidl login") }
        if st == .success { break }
    }
    if let acc = try await client.account() {
        print("登录成功：\(acc.name)\(acc.isVip ? "（\(acc.vipLabel.isEmpty ? "大会员" : acc.vipLabel)）" : "")")
    }
    finish(0)
case "logout":
    client.logout()
    print("已退出登录")
    finish(0)
case "whoami":
    if let acc = try await client.account() {
        print("\(acc.name) (uid \(acc.mid))\(acc.isVip ? " · \(acc.vipLabel.isEmpty ? "大会员" : acc.vipLabel)" : "")")
    } else {
        print("未登录（只能下载 480P，运行 bilidl login 扫码登录）")
    }
    finish(0)
default: break
}

guard let ffmpeg = FFmpeg.locate(custom: settings.ffmpegPath) else { fail(BiliError.ffmpegMissing.localizedDescription) }
Log.environment(ffmpeg: ffmpeg, settings: settings, app: "bilidl \(CommandLine.arguments.dropFirst().joined(separator: " "))")

let parsed: ParsedList
do { parsed = try await client.parse(target) } catch { fail("解析失败：\(error.localizedDescription)") }

print("《\(parsed.title)》 \(parsed.kind.rawValue)，共 \(parsed.entries.count) 项")
if let s = parsed.season, parsed.kind == .video {
    print("提示：该视频属于合集《\(s.title)》（\(s.count) 集），整个合集可用 --all 下载")
}
var entries = parsed.entries.filter { selectAll || $0.defaultSelected }
if selectAll, parsed.kind == .video, let s = parsed.season {
    entries = try await client.season(mid: s.mid, seasonId: s.id).entries
}
if listOnly {
    for e in parsed.entries { print("  \(e.defaultSelected ? "✓" : " ") \(e.fileName)") }
    finish(0)
}
if !client.isLoggedIn && settings.quality > 32 {
    print("⚠️  未登录，最高只能下载 480P。运行 `bilidl login` 扫码登录后可下载 1080P。")
}

let pipeline = DownloadPipeline(client: client, settings: settings, ffmpeg: ffmpeg)
var failed = 0

// 列表接口拿不到 cid 的条目先补全
var queue: [VideoEntry] = []
for e in entries {
    if e.cid == 0 {
        do { queue += try await client.expand(e) } catch {
            print("✗ \(e.fileName)：\(error.localizedDescription)")
            failed += 1
        }
    } else {
        queue.append(e)
    }
}

final class Printer: @unchecked Sendable {
    let lock = NSLock()
    var lines: [String: String] = [:]
    func set(_ id: String, _ line: String) {
        lock.withLock {
            lines[id] = line
            printProgress(lines.values.sorted().joined(separator: " | ").prefix(160).description)
        }
    }
    func done(_ id: String, _ line: String) {
        lock.withLock {
            lines[id] = nil
            FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
            print(line)
        }
    }
}
let printer = Printer()

await withTaskGroup(of: Bool.self) { group in
    let queue = queue
    var iterator = queue.enumerated().makeIterator()
    func addNext() async -> Bool {
        guard let (i, e) = iterator.next() else { return false }
        // 等当前项实际取得下载名额后再提交下一项，而不是依赖任务启动顺序。
        let (started, signal) = AsyncStream<Void>.makeStream()
        group.addTask {
            defer { signal.finish() }
            let tag = "[\(i + 1)/\(queue.count)]"
            do {
                let r = try await pipeline.run(e, downloadStarted: {
                    signal.yield(())
                    signal.finish()
                }) { u in
                    let pct = u.progress.map { " \(Int($0 * 100))%" } ?? ""
                    printer.set(e.id, "\(tag) \(u.detail)\(u.detail.contains("%") ? "" : pct)")
                }
                printer.done(e.id, "\(r.skipped ? "↷" : "✓") \(tag) \(r.file.lastPathComponent)\(r.note.isEmpty ? "" : "（\(r.note)）")")
                return true
            } catch {
                printer.done(e.id, "✗ \(tag) \(e.fileName)：\(error.localizedDescription)")
                return false
            }
        }
        for await _ in started { break }
        return true
    }
    for _ in 0 ..< 2 { if !(await addNext()) { break } }
    for await ok in group {
        if !ok { failed += 1 }
        _ = await addNext()
    }
}

print(failed == 0 ? "全部完成，保存在 \(settings.downloadDir)" : "完成，\(failed) 项失败")
print("日志：\(Log.shared.currentFile.path)")
finish(failed == 0 ? 0 : 1)
