import AppKit
import BiliCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            Form {
                Section("保存") {
                    LabeledContent("下载位置") {
                        HStack {
                            Text(model.settings.downloadDir).lineLimit(1).truncationMode(.head)
                                .foregroundStyle(.secondary)
                            Button("选择…") { chooseFolder() }
                        }
                    }
                    LabeledContent("队列模式", value: "下载 1 个＋合成 1 个")
                    Text("合成当前视频时下载下一个；下一个下载完成后等待合成，避免同时渲染多个视频。")
                        .font(.caption).foregroundStyle(.secondary)
                    Stepper(model.settings.autoRetry == 0 ? "失败后不自动重试" : "失败后自动重试 \(model.settings.autoRetry) 次",
                            value: $model.settings.autoRetry, in: 0 ... 5)
                        .help("网络、CDN、风控、ffmpeg 等临时错误会自动重试；已完成的下载、合并和渲染分段会保留，不会从头再来")
                }
                Section {
                    Picker("默认画质", selection: $model.settings.quality) {
                        ForEach(Quality.all, id: \.qn) { q in Text(q.name).tag(q.qn) }
                    }
                    Picker("视频编码", selection: $model.settings.codec) {
                        ForEach(VideoCodec.allCases) { c in Text(c.label).tag(c) }
                    }
                    Toggle("有 60 帧版本时优先下载", isOn: $model.settings.prefer60)
                } header: {
                    Text("画质")
                } footer: {
                    Text("选的画质不存在时，自动取不超过它的最高画质。1080P 需要登录；1080P60、1080P 高码率、4K 需要大会员。H.264 兼容性最好，HEVC/AV1 体积更小。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("下载", systemImage: "arrow.down.circle") }

            Form {
                Section {
                    Picker("弹幕", selection: $model.settings.danmakuMode) {
                        ForEach(DanmakuMode.allCases) { m in Text(m.label).tag(m) }
                    }
                    if model.settings.danmakuMode == .burn {
                        Picker("弹幕绘制", selection: $model.settings.danmakuRenderer) {
                            ForEach(DanmakuRenderer.allCases) { r in Text(r.label).tag(r) }
                        }
                        Toggle("输出 60fps", isOn: $model.settings.burn60fps)
                        Picker("编码方式", selection: $model.settings.burnEncoder) {
                            ForEach(BurnEncoder.allCases) { e in Text(e.label).tag(e) }
                        }
                        if model.settings.burnEncoder != .x264 {
                            Picker("硬件目标码率", selection: $model.settings.hardwareBitrateKbps) {
                                Text("自动（体积较大）").tag(0)
                                Text("3 Mbps（体积优先）").tag(3000)
                                Text("5 Mbps").tag(5000)
                                Text("8 Mbps").tag(8000)
                                Text("12 Mbps").tag(12000)
                            }
                        }
                        if model.settings.danmakuRenderer == .metal {
                            Text("实验功能：只支持本程序弹幕和普通 SDR 视频；硬件编码使用共享帧缓冲，自动模式使用单段。软件编码的长视频最多自动分成 4 段。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if model.settings.burnEncoder == .x264 {
                            Picker("输出体积", selection: $model.settings.burnQuality) {
                                ForEach(BurnQuality.allCases) { q in Text(q.label).tag(q) }
                            }
                            .help("实测各档画质（VMAF）基本一致，越小的档位编码越慢")
                        }
                        Picker("并行渲染", selection: $model.settings.burnSegments) {
                            Text("自动").tag(0)
                            ForEach(1 ... 8, id: \.self) { n in Text(n == 1 ? "不分段" : "\(n) 段").tag(n) }
                        }
                        .help("弹幕渲染（libass）是单线程的，长视频切成几段同时渲染再无损拼接，弹幕密集时能快 2~3 倍")
                        Toggle("同时保留无弹幕原版和 ASS 字幕", isOn: $model.settings.keepOriginal)
                    }
                    Toggle("同时保存 XML 弹幕文件", isOn: $model.settings.saveXML)
                } header: {
                    Text("弹幕")
                } footer: {
                    Text("烧录：把弹幕直接画进画面，任何播放器都能看到；开启 60fps 后弹幕滚动更顺滑，但需要重新编码，耗时较长。\nASS 字幕：不重新编码，用 IINA / VLC / mpv 播放时自动加载同名字幕。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("弹幕样式") {
                    Picker("字体", selection: $model.settings.danmakuStyle.fontName) {
                        ForEach(["得意黑", "Heiti SC", "Hiragino Sans GB", "STHeiti", "Arial Unicode MS"], id: \.self) { Text($0 == "Smiley Sans" ? "得意黑" : $0).tag($0) }
                    }
                    SliderRow(title: "字号", value: $model.settings.danmakuStyle.fontScale, range: 0.6 ... 2.0, format: "%.0f%%", scale: 100)
                    SliderRow(title: "不透明度", value: $model.settings.danmakuStyle.opacity, range: 0.2 ... 1, format: "%.0f%%", scale: 100)
                    SliderRow(title: "描边不透明度", value: $model.settings.danmakuStyle.outlineOpacity, range: 0 ... 1, format: "%.0f%%", scale: 100)
                    SliderRow(title: "滚动时长", value: $model.settings.danmakuStyle.scrollDuration, range: 5 ... 15, format: "%.1f 秒", scale: 1)
                    Picker("显示区域", selection: $model.settings.danmakuStyle.displayArea) {
                        Text("全屏").tag(1.0)
                        Text("3/4 屏").tag(0.75)
                        Text("半屏").tag(0.5)
                        Text("1/4 屏").tag(0.25)
                    }
                    Toggle("加厚描边（默认关闭，参考图细描边）", isOn: $model.settings.danmakuStyle.heavyOutline)
                    Text("暂不支持智能防挡人物；显示区域仅限制弹幕轨道，不会识别人脸。高级弹幕暂不支持。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("屏蔽顶部弹幕", isOn: $model.settings.danmakuStyle.blockTop)
                    Toggle("屏蔽底部弹幕", isOn: $model.settings.danmakuStyle.blockBottom)
                    Toggle("屏蔽彩色弹幕", isOn: $model.settings.danmakuStyle.blockColored)
                    Toggle("放不下时允许重叠", isOn: $model.settings.danmakuStyle.allowOverlap)
                    Button("恢复默认样式") { model.settings.danmakuStyle = DanmakuStyle() }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("弹幕", systemImage: "text.bubble") }

            Form {
                Section {
                    Toggle("微信分享模式", isOn: $model.settings.wechatShareEnabled)
                        .toggleStyle(.checkbox)
                    if model.settings.wechatShareEnabled {
                        SliderRow(title: "播放速度", value: $model.settings.wechatShareSpeed, range: 1 ... 2, format: "%.2f 倍", scale: 1)
                        Picker("最长边", selection: $model.settings.wechatShareMaxDimension) {
                            Text("640px（更小）").tag(640)
                            Text("960px（默认）").tag(960)
                            Text("1280px（更清晰）").tag(1280)
                        }
                        Stepper("视频码率 \(model.settings.wechatShareVideoKbps) kbps", value: $model.settings.wechatShareVideoKbps, in: 400 ... 2000, step: 100)
                        Button("恢复分享默认参数") {
                            model.settings.wechatShareSpeed = 1.5
                            model.settings.wechatShareVideoKbps = 1000
                            model.settings.wechatShareMaxDimension = 960
                        }
                    }
                } header: {
                    Text("微信分享")
                } footer: {
                    Text("额外生成分享版 MP4，保留正常版本。默认 1.5 倍速、最长边 960px、30fps；音调保持不变，弹幕同步加速。\n默认原片每分钟约生成 5.3MB。这是本程序的压缩预设，微信仍可能二次压缩。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("微信分享", systemImage: "square.and.arrow.up") }

            Form {
                Section {
                    LabeledContent("当前使用") {
                        Text(model.ffmpeg?.path ?? "未找到").foregroundStyle(model.ffmpeg == nil ? .red : .secondary)
                    }
                    HStack {
                        TextField("自定义路径（留空自动检测）", text: $model.settings.ffmpegPath)
                        Button("检测") { model.refreshFFmpeg() }
                    }
                } header: {
                    Text("ffmpeg")
                } footer: {
                    Text("用于合并音视频和渲染弹幕。没有的话在终端执行：brew install ffmpeg")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("日志位置") {
                        HStack {
                            Text(Log.directory.path).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                            Button("打开") { model.openLogFolder() }
                        }
                    }
                } header: {
                    Text("日志")
                } footer: {
                    Text("记录每个任务各阶段耗时、选中的清晰度和 CDN 节点、下载速度、弹幕数量、ffmpeg 命令及编码速度，保留 14 天。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("高级", systemImage: "gearshape.2") }
        }
        .frame(width: 520, height: 560)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.directoryURL = URL(fileURLWithPath: model.settings.downloadDir)
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.downloadDir = url.path
        }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String
    let scale: Double

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range).frame(width: 200)
                Text(String(format: format, value * scale)).monospacedDigit().frame(width: 56, alignment: .trailing)
            }
        }
    }
}
