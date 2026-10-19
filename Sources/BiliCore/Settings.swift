import Foundation

public enum DanmakuMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, assFile, burn
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .none: "不下载弹幕"
        case .assFile: "保存为 ASS 字幕文件"
        case .burn: "烧录进视频"
        }
    }
}

public struct AppSettings: Codable, Sendable, Equatable {
    public var downloadDir: String = WorkLayout.defaultDirectory.path
    public var workLayout: WorkLayout { WorkLayout(directory: downloadDir) }
    public var quality = 80
    public var codec = VideoCodec.avc
    /// 有 1080P60（大会员）时优先下载
    public var prefer60 = true
    public var concurrency = 2
    /// 失败后自动重试次数（只针对网络/CDN/ffmpeg 等临时性错误）
    public var autoRetry = 2
    public var danmakuMode = DanmakuMode.burn
    /// 烧录弹幕时输出 60fps
    public var burn60fps = true
    public var burnEncoder = BurnEncoder.h264
    public var danmakuRenderer = DanmakuRenderer.metal
    /// 0 使用自动码率；硬件输出的速度/体积与软件 CRF 档位不可直接等同
    public var hardwareBitrateKbps = 3000
    /// 软件编码的体积档位
    public var burnQuality = BurnQuality.size
    /// 烧录时并行渲染的段数，0 = 自动（libass 单线程，弹幕密集时并行能快 2~3 倍）
    public var burnSegments = 0
    /// 兼容旧配置；原片和 ASS 现在始终保留在 00_cache。
    public var keepOriginal = false
    public var saveXML = false
    public var wechatShareEnabled = false
    public var danmakuStyle = DanmakuStyle()
    public var danmakuStyleVersion = 4
    public var ffmpegPath = ""

    public init() {}

    // 新增字段时旧配置也能读出来
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func load<T: Decodable>(_ key: CodingKeys, _ target: inout T) {
            if let v = try? c.decode(T.self, forKey: key) { target = v }
        }
        load(.downloadDir, &downloadDir)
        let oldDefault = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bilibili", isDirectory: true).standardizedFileURL
        if WorkLayout(directory: downloadDir).root == oldDefault
            || WorkLayout(directory: downloadDir).root == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("download/bilibili-downloader", isDirectory: true) { downloadDir = WorkLayout.defaultDirectory.path }
        load(.quality, &quality)
        load(.codec, &codec)
        load(.prefer60, &prefer60)
        load(.concurrency, &concurrency)
        load(.autoRetry, &autoRetry)
        load(.danmakuMode, &danmakuMode)
        load(.burn60fps, &burn60fps)
        load(.burnEncoder, &burnEncoder)
        load(.danmakuRenderer, &danmakuRenderer)
        load(.hardwareBitrateKbps, &hardwareBitrateKbps)
        load(.burnQuality, &burnQuality)
        load(.burnSegments, &burnSegments)
        load(.keepOriginal, &keepOriginal)
        load(.saveXML, &saveXML)
        load(.wechatShareEnabled, &wechatShareEnabled)
        load(.danmakuStyle, &danmakuStyle)
        // 迁移旧版配置到用户指定的截图预设；之后保留用户的自定义值。
        let styleVersion = (try? c.decode(Int.self, forKey: .danmakuStyleVersion)) ?? 0
        if styleVersion < 1 {
            danmakuStyle = DanmakuStyle()
        } else if styleVersion < 2 {
            // 仅更新本次指定的字体与描边，保留字号、区域等已有设置。
            danmakuStyle.fontName = "得意黑"
            danmakuStyle.outlineOpacity = 0.3
        }
        if styleVersion < 3 {
            danmakuStyle.opacity = 0.95
            danmakuStyle.outlineOpacity = 0.85
            danmakuStyle.heavyOutline = false
        }
        if styleVersion < 4 && danmakuStyle.fontName == "Smiley Sans" {
            danmakuStyle.fontName = "得意黑"
        }
        load(.ffmpegPath, &ffmpegPath)
    }

    /// 和登录 Cookie 放在一起，App 与命令行共用
    public static var fileURL: URL { AppPaths.supportDir.appendingPathComponent("settings.json") }

    public static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    public func save() {
        try? FileManager.default.createDirectory(at: AppPaths.supportDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: Self.fileURL, options: .atomic) }
    }
}
