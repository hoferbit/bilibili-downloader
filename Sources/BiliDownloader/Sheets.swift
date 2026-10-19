import BiliCore
import CoreImage
import SwiftUI

struct SelectionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var selection: Selection
    @State private var filter = ""

    private var visible: [VideoEntry] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        return f.isEmpty ? selection.list.entries : selection.list.entries.filter { $0.title.localizedCaseInsensitiveContains(f) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selection.list.title).font(.title3.bold()).lineLimit(2)
                    Text("\(selection.list.kind.rawValue) · 共 \(selection.list.entries.count) 项 · 已选 \(selection.selected.count) 项")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let s = selection.list.season, selection.list.kind == .video || selection.list.kind == .multiPart {
                HStack {
                    Image(systemName: "rectangle.stack.fill").foregroundStyle(.pink)
                    Text("这个视频属于合集《\(s.title)》（\(s.count) 集）")
                    Spacer()
                    Button {
                        Task { await model.loadSeason(into: selection) }
                    } label: {
                        if selection.loadingSeason { ProgressView().controlSize(.small) } else { Text("加载整个合集") }
                    }
                    .disabled(selection.loadingSeason)
                }
                .font(.callout)
                .padding(10)
                .background(Color.pink.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Button("全选") { selection.selected.formUnion(visible.map(\.id)) }
                Button("全不选") { selection.selected.subtract(visible.map(\.id)) }
                Button("反选") {
                    for e in visible {
                        if selection.selected.contains(e.id) { selection.selected.remove(e.id) } else { selection.selected.insert(e.id) }
                    }
                }
                Spacer()
                TextField("筛选标题", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
            .controlSize(.small)

            List(visible) { e in
                Toggle(isOn: Binding(
                    get: { selection.selected.contains(e.id) },
                    set: { on in if on { selection.selected.insert(e.id) } else { selection.selected.remove(e.id) } }
                )) {
                    HStack {
                        Text(e.fileName).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if e.duration > 0 {
                            Text(String(format: "%d:%02d", e.duration / 60, e.duration % 60))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))

            HStack {
                Text("保存到：\(model.settings.downloadDir)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("下载 \(selection.selected.count) 项") { model.confirm(selection) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
    }
}

struct LoginSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var qr: NSImage?
    @State private var state: QRLoginState = .waiting
    @State private var error: String?
    @State private var generation = 0

    var body: some View {
        VStack(spacing: 16) {
            Text("扫码登录哔哩哔哩").font(.title3.bold())
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.white)
                if let qr {
                    Image(nsImage: qr).interpolation(.none).resizable().padding(12)
                        .opacity(state == .expired ? 0.15 : 1)
                } else {
                    ProgressView()
                }
                if state == .expired {
                    Button("二维码已过期，点击刷新") { generation += 1 }
                } else if state == .scanned {
                    Label("已扫码，请在手机上确认", systemImage: "checkmark.circle.fill")
                        .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(width: 220, height: 220)
            Text(error ?? "打开哔哩哔哩 App →「我的」右上角扫一扫")
                .font(.callout).foregroundStyle(error == nil ? Color.secondary : Color.red)
                .multilineTextAlignment(.center)
            Text("登录信息只保存在本机（~/Library/Application Support/BiliDownloader）")
                .font(.caption).foregroundStyle(.tertiary)
            Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 340)
        .task(id: generation) { await loop() }
    }

    private func loop() async {
        state = .waiting
        qr = nil
        error = nil
        do {
            let (url, key) = try await model.client.qrGenerate()
            qr = Self.render(url)
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 1_500_000_000)
                let s = try await model.client.qrPoll(key: key)
                state = s
                if s == .expired { return }
                if s == .success {
                    await model.refreshAccount()
                    dismiss()
                    return
                }
            }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func render(_ text: String) -> NSImage? {
        guard let ci = QRCode.ciImage(text) else { return nil }
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
