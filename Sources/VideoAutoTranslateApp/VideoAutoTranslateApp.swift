import SwiftUI
import AppKit
import VideoAutoTranslateCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 将进程激活策略明确设置为标准 macOS 桌面图形应用 (含 Dock 图标和前台窗口层级)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async {
            if let window = NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    // 当用户在 Cmd+Tab 或 Dock 中重新唤起应用时，确保窗口前置
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        for window in sender.windows {
            window.makeKeyAndOrderFront(nil)
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if let window = NSApp.keyWindow ?? NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }

    // 支持拖拽到 App 图标或从访达右键使用本应用打开视频
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let first = filenames.first, FileManager.default.fileExists(atPath: first) {
            NotificationCenter.default.post(
                name: Notification.Name("com.videoautotranslate.openVideoFile"),
                object: URL(fileURLWithPath: first)
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 应用退出时终止静默托管的后台 ASR 进程，释放显存与端口
        ASRSidecarManager.shared.stop()
    }
}

@main
struct VideoAutoTranslateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            MainView()
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}
