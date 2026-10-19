import BiliCore
import SwiftUI

struct SystemUsageView: View {
    @State private var probe = SystemUsageProbe()
    @State private var cpu: Double?
    @State private var gpu: Double?

    var body: some View {
        HStack(spacing: 18) {
            Text("整机使用率").foregroundStyle(.secondary)
            meter("CPU", value: cpu, color: .blue)
            meter("GPU", value: gpu, color: .green)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .help("每秒更新。CPU 为所有核心归一化后的整机占用，GPU 为整机图形引擎占用；均不是下载器单独占用。GPU 数值不代表专用视频编码器的占用。无法读取时显示 —。")
        .task {
            while !Task.isCancelled {
                let usage = await probe.sample()
                guard !Task.isCancelled else { break }
                cpu = usage.cpu
                gpu = usage.gpu
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { break }
            }
        }
    }

    private func meter(_ title: String, value: Double?, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(title)
            ProgressView(value: value ?? 0, total: 100)
                .tint(color).frame(width: 60)
            Text(value.map { String(format: "%.0f%%", $0) } ?? "—")
                .monospacedDigit().frame(width: 35, alignment: .trailing)
        }
    }
}
