import AppKit
import BiliCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 以 SwiftPM 可执行文件直接运行时也能显示窗口和 Dock 图标
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct BiliDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("B站下载器") {
            ContentView()
                .environment(model)
                .frame(minWidth: 680, minHeight: 440)
        }
        .defaultSize(width: 860, height: 600)
        .commands {
            CommandGroup(after: .newItem) {
                Button("粘贴链接并解析") { Task { await model.pasteAndParse() } }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("打开下载文件夹") { model.openDownloadFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("打开日志文件夹") { model.openLogFolder() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
