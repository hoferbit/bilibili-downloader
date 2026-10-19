import BiliCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            InputBar()
                .padding(14)
            SystemUsageView()
            Notices()
            Divider()
            if model.jobs.isEmpty {
                ContentUnavailableView {
                    Label("还没有下载任务", systemImage: "arrow.down.circle")
                } description: {
                    Text("粘贴视频、多P、合集、收藏夹、番剧或 UP 主空间链接，按回车解析。\n⇧⌘V 可直接粘贴剪贴板里的链接。")
                }
            } else {
                List {
                    ForEach(model.jobs) { job in
                        JobRow(job: job)
                    }
                }
                .listStyle(.inset)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if model.failedCount > 0 {
                    Button("全部重试", systemImage: "arrow.clockwise") { model.retryAllFailed() }
                        .help("重试所有失败的任务")
                }
                Button("清除已完成", systemImage: "checkmark.circle") { model.clearFinished() }
                    .help("清除已完成的任务")
                    .disabled(!model.jobs.contains { $0.stage == .finished || $0.stage == .skipped || $0.stage == .cancelled })
                Button("打开下载文件夹", systemImage: "folder") { model.openDownloadFolder() }
                    .help("打开下载文件夹")
                AccountButton()
            }
        }
        .navigationSubtitle(model.activeCount > 0 ? "\(model.activeCount) 个任务进行中" : "")
        .sheet(item: $model.selection) { sel in
            SelectionSheet(selection: sel)
        }
        .sheet(isPresented: $model.showLogin) {
            LoginSheet()
        }
        .alert("出错了", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct InputBar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("粘贴 B 站链接 / BV 号 / 分享文案", text: $model.urlText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($focused)
                    .onSubmit { Task { await model.parse() } }
                Button {
                    Task { await model.parse() }
                } label: {
                    if model.parsing {
                        ProgressView().controlSize(.small).frame(width: 36)
                    } else {
                        Text("解析").frame(width: 36)
                    }
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(model.urlText.trimmingCharacters(in: .whitespaces).isEmpty || model.parsing)
            }
            HStack(spacing: 14) {
                Picker("画质", selection: $model.settings.quality) {
                    ForEach(Quality.all, id: \.qn) { q in Text(q.name).tag(q.qn) }
                }
                .fixedSize()
                Picker("弹幕", selection: $model.settings.danmakuMode) {
                    ForEach(DanmakuMode.allCases) { m in Text(m.label).tag(m) }
                }
                .fixedSize()
                if model.settings.danmakuMode == .burn {
                    Toggle("输出 60fps", isOn: $model.settings.burn60fps)
                        .help("弹幕按 60 帧渲染，滚动更顺滑（原视频帧会复制补足）")
                }
                Spacer()
            }
            .controlSize(.small)
            .disabled(model.settings.wechatShareEnabled)
            HStack(spacing: 8) {
                Toggle("微信分享模式", isOn: $model.settings.wechatShareEnabled)
                    .toggleStyle(.checkbox)
                    .help("直接下载最低分辨率原片，只合并音视频，不做加工")
                if model.settings.wechatShareEnabled {
                    Text("最低分辨率原片 · 不加工")
                        .foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
        }
        .onAppear { focused = true }
    }
}

struct Notices: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 6) {
            if model.ffmpeg == nil {
                Banner(icon: "exclamationmark.triangle.fill", color: .orange,
                       text: "未找到 ffmpeg，无法合并音视频。请在终端执行 brew install ffmpeg，或在设置里指定路径。") {
                    Button("重新检测") { model.refreshFFmpeg() }
                }
            }
            if !model.settings.wechatShareEnabled && model.account == nil && model.settings.quality > 32 {
                Banner(icon: "person.crop.circle.badge.exclamationmark", color: .pink,
                       text: "未登录时 B 站最高只给 480P，扫码登录后即可下载 1080P。") {
                    Button("扫码登录") { model.showLogin = true }
                }
            } else if let acc = model.account, !model.settings.wechatShareEnabled && !acc.isVip && [116, 112, 120, 125, 126, 127].contains(model.settings.quality) {
                Banner(icon: "info.circle", color: .blue,
                       text: "\(Quality.name(model.settings.quality)) 需要大会员，非大会员会自动降到 1080P。") { EmptyView() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, model.ffmpeg == nil || model.account == nil ? 10 : 0)
    }
}

struct Banner<Trailing: View>: View {
    let icon: String
    let color: Color
    let text: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            trailing.controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct AccountButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let acc = model.account {
            Menu {
                Text(acc.name)
                Text(acc.isVip ? (acc.vipLabel.isEmpty ? "大会员" : acc.vipLabel) : "普通用户（最高 1080P）")
                Divider()
                Button("退出登录") { model.logout() }
            } label: {
                HStack(spacing: 6) {
                    if let img = model.avatar {
                        Image(nsImage: img).resizable().frame(width: 20, height: 20).clipShape(Circle())
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                    }
                    Text(acc.name).lineLimit(1)
                    if acc.isVip {
                        Text("大会员").font(.caption2.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.pink, in: RoundedRectangle(cornerRadius: 3))
                    }
                }
            }
            .help("账号")
        } else {
            Button("扫码登录", systemImage: "qrcode") { model.showLogin = true }
                .help("用哔哩哔哩 App 扫码登录")
        }
    }
}

struct JobRow: View {
    @Environment(AppModel.self) private var model
    let job: DownloadJob

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            StageIcon(stage: job.stage)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.entry.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(job.entry.title)
                HStack(spacing: 6) {
                    if let folder = job.entry.folder {
                        Text(folder).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
                        Text("·")
                    }
                    Text(job.detail)
                        .lineLimit(2)
                        .foregroundStyle(job.stage == .failed ? Color.red : job.stage == .retrying ? Color.orange : Color.secondary)
                        .textSelection(.enabled)
                    Spacer(minLength: 6)
                    if !job.quality.isEmpty {
                        Text(job.quality).monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !job.stage.isTerminal && job.stage != .waiting && job.stage != .retrying {
                    if let p = job.progress {
                        ProgressView(value: p).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                }
            }
            HStack(spacing: 4) {
                switch job.stage {
                case .finished, .skipped:
                    Button("在访达中显示", systemImage: "magnifyingglass") { model.reveal(job) }
                case .failed, .cancelled:
                    Button("重试", systemImage: "arrow.clockwise") { model.retry(job) }
                    Button("移除", systemImage: "xmark") { model.remove(job) }
                default:
                    Button("取消", systemImage: "stop.fill") { model.cancel(job) }
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .contextMenu {
            if job.output != nil { Button("在访达中显示") { model.reveal(job) } }
            Button("复制视频链接") {
                let url = job.entry.epid.map { "https://www.bilibili.com/bangumi/play/ep\($0)" }
                    ?? "https://www.bilibili.com/video/\(job.entry.bvid)"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }
            Divider()
            Button("移除") { model.remove(job) }
        }
    }
}

struct StageIcon: View {
    let stage: JobStage

    var body: some View {
        switch stage {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .resolving: Image(systemName: "magnifyingglass").foregroundStyle(.blue)
        case .downloading: Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
        case .merging: Image(systemName: "square.stack.3d.down.forward.fill").foregroundStyle(.indigo)
        case .danmaku: Image(systemName: "text.bubble.fill").foregroundStyle(.pink)
        case .rendering: Image(systemName: "sparkles.tv.fill").foregroundStyle(.pink)
        case .retrying: Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
        case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "checkmark.circle").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }
}
