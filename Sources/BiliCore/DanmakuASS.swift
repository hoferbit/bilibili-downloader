import CoreText
import Foundation

public struct DanmakuStyle: Codable, Sendable, Equatable {
    /// 必须是 libass 能直接读取的字体：系统的苹方放在受保护目录里，libass 打不开，会逐字回退导致渲染极慢
    public var fontName = "得意黑"
    /// 字号缩放，1.0 时 1080P 画面上普通弹幕约 43px
    public var fontScale = 1.7
    public var opacity = 0.95
    /// 参考图的清晰细描边：85% 不透明（15% 透明），独立于字芯
    public var outlineOpacity = 0.85
    /// 滚动弹幕从右到左走完全程的秒数，越大越慢
    public var scrollDuration = 9.0
    /// 顶部/底部弹幕停留秒数
    public var fixedDuration = 4.5
    /// 弹幕可占用的画面高度比例
    public var displayArea = 0.25
    /// 重墨近似：加粗文字和更厚描边
    public var heavyOutline = false
    public var blockTop = false
    public var blockBottom = false
    public var blockColored = false
    /// 同屏放不下时是否允许重叠（关闭则丢弃，更清爽）
    public var allowOverlap = false

    public init() {}

    // 新增字段时旧配置也能读出来
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func load<T: Decodable>(_ key: CodingKeys, _ target: inout T) {
            if let v = try? c.decode(T.self, forKey: key) { target = v }
        }
        load(.heavyOutline, &heavyOutline)
        load(.fontName, &fontName)
        load(.fontScale, &fontScale)
        load(.opacity, &opacity)
        load(.outlineOpacity, &outlineOpacity)
        load(.scrollDuration, &scrollDuration)
        load(.fixedDuration, &fixedDuration)
        load(.displayArea, &displayArea)
        load(.blockTop, &blockTop)
        load(.blockBottom, &blockBottom)
        load(.blockColored, &blockColored)
        load(.allowOverlap, &allowOverlap)
    }
}

private final class TextMeasurer {
    private let font: CTFont
    private let baseSize: CGFloat

    init(fontName: String, size: CGFloat) {
        var f = CTFontCreateWithName((fontName == "得意黑" ? "Smiley Sans" : fontName) as CFString, size, nil)
        if let bold = CTFontCreateCopyWithSymbolicTraits(f, size, nil, .traitBold, .traitBold) { f = bold }
        font = f
        baseSize = size
    }

    func width(_ s: String, size: CGFloat) -> Double {
        let attrs = [kCTFontAttributeName: font] as CFDictionary
        guard let str = CFAttributedStringCreate(nil, s as CFString, attrs) else { return Double(s.count) * size }
        let line = CTLineCreateWithAttributedString(str)
        return CTLineGetTypographicBounds(line, nil, nil, nil) * Double(size / baseSize)
    }
}

public struct DanmakuASSResult: Sendable {
    public var text: String
    /// 实际显示的条数
    public var count: Int
    /// 高级弹幕、被屏蔽的类型
    public var filtered: Int
    /// 同屏轨道放不下而丢弃的
    public var dropped: Int
}

public enum DanmakuASS {
    // 旧 ASS 可能含 NUL，libass 会在该处截断整个文件；不可复用旧版缓存。
    static let cacheVersion = "ass-controls-v2"

    /// 把弹幕排版成 ASS 字幕。会测量每条文字的真实宽度，按“前车尾部进场 + 后车追不上前车”规则分配轨道，避免重叠。
    public static func make(_ comments: [DanmakuComment], width: Int, height: Int,
                            style: DanmakuStyle) -> DanmakuASSResult {
        let W = Double(width), H = Double(height)
        let base = min(W, H) * 0.04 * style.fontScale
        // 行高取整除画面高度，顶部和底部弹幕的轨道能严丝合缝地拼起来
        let fixedRows = max(1, Int(H / (base * 1.2)))
        let rowH = H / Double(fixedRows)
        let outline = max(1.0, base / (style.heavyOutline ? 22 : 38))
        let measurer = TextMeasurer(fontName: style.fontName, size: CGFloat(base))
        let alpha = String(format: "%02X", Int(((1 - min(max(style.opacity, 0), 1)) * 255).rounded()))

        let outlineAlpha = String(format: "%02X", Int(((1 - min(max(style.outlineOpacity, 0), 1)) * 255).rounded()))

        let scrollRows = max(1, Int((H * style.displayArea / rowH).rounded()))

        struct Lane { var start: Double; var width: Double }
        var scroll = [Lane?](repeating: nil, count: scrollRows)
        var reverse = [Lane?](repeating: nil, count: scrollRows)
        // 顶部、底部弹幕共用一组轨道：顶部从上往下找，底部从下往上找，互不遮挡
        var fixed = [Double](repeating: -1, count: fixedRows)
        let topRows = max(1, min(fixedRows, scrollRows))

        let D = style.scrollDuration
        func laneFree(_ lane: Lane?, t: Double, w: Double) -> Bool {
            guard let p = lane else { return true }
            let pSpeed = (W + p.width) / D
            let speed = (W + w) / D
            let tailEntered = t >= p.start + p.width / pSpeed
            let cannotCatch = t + W / speed >= p.start + D
            return tailEntered && cannotCatch
        }
        // 找到连续 need 条空闲轨道的起始行
        func findRow(_ count: Int, need: Int, free: (Int) -> Bool) -> Int? {
            guard need <= count else { return free(0) ? 0 : nil }
            var i = 0
            while i + need <= count {
                if let bad = (i ..< i + need).first(where: { !free($0) }) { i = bad + 1 } else { return i }
            }
            return nil
        }

        var events: [String] = []
        events.reserveCapacity(comments.count)
        var filtered = 0, dropped = 0

        for c in comments {
            // 高级/代码弹幕无法用普通字幕表现
            if !(1 ... 6).contains(c.mode) || (style.blockTop && c.mode == 5) || (style.blockBottom && c.mode == 4)
                || (style.blockColored && c.color != 0xFFFFFF) {
                filtered += 1
                continue
            }

            // 弹幕来自外部输入。尤其是 NUL 会让 libass 静默忽略文件中所有后续事件。
            // 保留换行、制表符和 emoji 连接符；其余 C0/C1 在排版前移除，避免空白弹幕占用轨道。
            let cleaned = String(String.UnicodeScalarView(c.content.unicodeScalars.filter {
                ($0.value >= 0x20 && !(0x7F ... 0x9F).contains($0.value)) || $0 == "\n" || $0 == "\t"
            }))
            let lines = cleaned
                .replacingOccurrences(of: "/n", with: "\n").split(separator: "\n").map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !lines.isEmpty else { filtered += 1; continue }
            let fs = base * Double(min(max(c.fontSize, 12), 64)) / 25
            let w = (lines.map { measurer.width($0, size: CGFloat(fs)) }.max() ?? 0) + outline * 2
            let h = fs * 1.2 * Double(lines.count)
            let need = max(1, Int((h / rowH).rounded(.up)))
            let t = c.time

            var tags = ""
            if abs(fs - base) > 0.5 { tags += "\\fs\(Int(fs.rounded()))" }
            if c.color != 0xFFFFFF {
                let r = (c.color >> 16) & 0xFF, g = (c.color >> 8) & 0xFF, b = c.color & 0xFF
                tags += String(format: "\\c&H%02X%02X%02X&", b, g, r)
                // 深色文字用白色描边，否则看不清
                if Double(r) * 0.299 + Double(g) * 0.587 + Double(b) * 0.114 < 48 { tags += "\\3c&HFFFFFF&" }
            }
            let text = escape(lines)
            let end: Double

            switch c.mode {
            case 4, 5:
                let isTop = c.mode == 5
                let free: (Int) -> Bool = { fixed[$0] <= t }
                var row: Int?
                if isTop {
                    row = findRow(topRows, need: need, free: free)
                } else if need <= fixedRows {
                    row = stride(from: fixedRows - need, through: 0, by: -1)
                        .first { r in (r ..< r + need).allSatisfy(free) }
                }
                if row == nil && style.allowOverlap {
                    row = (isTop ? Array(0 ..< topRows) : Array((0 ..< fixedRows).reversed()))
                        .min { fixed[$0] < fixed[$1] }
                }
                guard let r = row else { dropped += 1; continue }
                end = t + style.fixedDuration
                for j in r ..< min(fixedRows, r + need) { fixed[j] = end }
                let pos = "\\an8\\pos(\(Int(W / 2)),\(Int(Double(r) * rowH)))"
                events.append(dialogue(t, end, "{\(pos)\(tags)}\(text)"))
            default:
                let isReverse = c.mode == 6
                let lanes = isReverse ? reverse : scroll
                var row = findRow(lanes.count, need: need) { laneFree(lanes[$0], t: t, w: w) }
                if row == nil && style.allowOverlap {
                    row = lanes.indices.min { (lanes[$0]?.start ?? -1) < (lanes[$1]?.start ?? -1) }
                }
                guard let r = row else { dropped += 1; continue }
                for j in r ..< min(lanes.count, r + need) {
                    if isReverse { reverse[j] = Lane(start: t, width: w) } else { scroll[j] = Lane(start: t, width: w) }
                }
                end = t + D
                let y = Int(Double(r) * rowH)
                let move = isReverse
                    ? "\\an7\\move(\(Int(-w)),\(y),\(Int(W)),\(y))"
                    : "\\an7\\move(\(Int(W)),\(y),\(Int(-w)),\(y))"
                events.append(dialogue(t, end, "{\(move)\(tags)}\(text)"))
            }
        }

        let header = """
        [Script Info]
        ; 由 BiliDownloader 生成
        ScriptType: v4.00+
        PlayResX: \(width)
        PlayResY: \(height)
        WrapStyle: 2
        ScaledBorderAndShadow: yes
        YCbCr Matrix: TV.709

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Danmaku,\(style.fontName),\(Int(base.rounded())),&H\(alpha)FFFFFF,&H\(alpha)FFFFFF,&H\(outlineAlpha)000000,&H\(outlineAlpha)000000,-1,0,0,0,100,100,0,0,1,\(String(format: "%.1f", outline)),0,7,0,0,0,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """
        return DanmakuASSResult(text: header + events.joined(separator: "\n") + "\n", count: events.count,
                                filtered: filtered, dropped: dropped)
    }

    private static func dialogue(_ start: Double, _ end: Double, _ text: String) -> String {
        "Dialogue: 0,\(timestamp(start)),\(timestamp(end)),Danmaku,,0,0,0,,\(text)"
    }

    static func timestamp(_ t: Double) -> String {
        let cs = max(0, Int((t * 100).rounded()))
        return String(format: "%d:%02d:%02d.%02d", cs / 360_000, cs / 6000 % 60, cs / 100 % 60, cs % 100)
    }

    private static func escape(_ lines: [String]) -> String {
        lines.map { line in
            var s = line.replacingOccurrences(of: "\\", with: "\\\u{200B}")
                .replacingOccurrences(of: "{", with: "\\{").replacingOccurrences(of: "}", with: "\\}")
            // 保留行首行尾空格
            if s.hasPrefix(" ") { s = "\\h" + s.dropFirst() }
            if s.hasSuffix(" ") { s = s.dropLast() + "\\h" }
            return s
        }.joined(separator: "\\N")
    }
}
