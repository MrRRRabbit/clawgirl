// ClawgirlApp.swift
// Clawgirl
//
// 文件用途：App 入口，负责创建应用程序根场景、注入全局依赖对象，以及注册全局菜单命令。
// 核心功能：
//   1. 使用 @main 标记，作为 SwiftUI App 生命周期的入口
//   2. 创建并管理 ChatManager 单例（StateObject，随 App 生命周期存活）
//   3. 通过 environmentObject 将 ChatManager 注入到整个视图树
//   4. 配置窗口样式（隐藏标题栏）
//   5. 注册"语音"菜单，提供语音输入快捷键 (⌘D)
//   6. 在菜单栏（status bar）添加常驻图标，关闭窗口后继续后台运行

import SwiftUI

/// AppDelegate：处理关闭窗口后不退出应用的行为
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

/// Clawgirl App 入口结构体
/// 使用 SwiftUI 的 App 协议定义应用程序生命周期
@main
struct ClawgirlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// 全局聊天管理器，作为 StateObject 贯穿整个应用生命周期
    /// 使用 @StateObject 确保 ChatManager 只被创建一次，不随视图重建而销毁
    @StateObject private var chatManager = ChatManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                // 将 chatManager 注入到视图层级，所有子视图均可通过 @EnvironmentObject 访问
                .environmentObject(chatManager)
        }
        // 隐藏窗口标题栏，实现沉浸式 UI 效果
        .windowStyle(.hiddenTitleBar)
        .commands {
            // 添加"语音"菜单栏菜单，方便用户通过菜单触发语音输入
            CommandMenu("语音") {
                Button("语音输入 (⌘D)") {
                    // 通过 NotificationCenter 广播语音输入事件，解耦视图与菜单逻辑
                    NotificationCenter.default.post(name: .ctrlDPressed, object: nil)
                }
                // 绑定键盘快捷键 ⌘D
                .keyboardShortcut("d", modifiers: .command)
            }
        }

        // 菜单栏常驻图标
        MenuBarExtra {
            MenuBarView(chatManager: chatManager)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
        }
    }
}

/// 菜单栏下拉菜单视图
struct MenuBarView: View {
    @ObservedObject var chatManager: ChatManager

    var body: some View {
        Button("打开主窗口") {
            openMainWindow()
        }

        Button("语音输入") {
            openMainWindow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NotificationCenter.default.post(name: .ctrlDPressed, object: nil)
            }
        }
        .keyboardShortcut("d", modifiers: .command)

        Toggle("语音唤醒", isOn: $chatManager.voiceWakeEnabled)
            .keyboardShortcut("e", modifiers: .command)

        Divider()

        Button("退出 Clawgirl") {
            NSApplication.shared.terminate(nil)
        }
    }

    private func openMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // 如果窗口已关闭，通过 openWindow 环境变量无法在此处使用，
            // 改为发送通知让系统打开新窗口
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}
