import SwiftUI
import AppKit
import VideoAutoTranslateCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 将进程激活策略明确设置为标准 macOS 桌面图形应用 (含 Dock 图标和前台窗口层级)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async {
            if NSApp.windows.isEmpty {
                let win = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                win.center()
                win.title = "VideoAutoTranslate"
                win.contentView = NSHostingView(rootView: MainView())
                win.makeKeyAndOrderFront(nil)
                self.window = win
            } else if let firstWindow = NSApp.windows.first {
                firstWindow.makeKeyAndOrderFront(nil)
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        return true
    }

    // 当用户在 Cmd+Tab 或 Dock 中重新唤起应用时，确保窗口前置
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let win = window {
            win.makeKeyAndOrderFront(nil)
        } else {
            for win in sender.windows {
                win.makeKeyAndOrderFront(nil)
            }
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppState.current?.confirmReplacingProject() == false ? .terminateCancel : .terminateNow
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
        Window("VideoAutoTranslate", id: "mainWindow") {
            MainView()
                .frame(minWidth: 960, minHeight: 600)
        }
        .commands { ProjectCommands() }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}

struct ProjectCommands: Commands {
    @FocusedObject var appState: AppState?
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("打开工程…") { appState?.openProjectInteractively() }.keyboardShortcut("o")
            Button("保存工程") { appState?.saveProjectInteractively() }.keyboardShortcut("s")
            Button("工程另存为…") { appState?.saveProjectInteractively(chooseNewURL: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }
}
