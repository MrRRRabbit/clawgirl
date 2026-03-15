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

/// AppDelegate：处理窗口关闭行为和 Dock 图标点击重新打开窗口
class AppDelegate: NSObject, NSApplicationDelegate {
    /// 保存主窗口引用，确保关闭/隐藏后仍能找到并恢复
    static weak var mainWindow: NSWindow?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// 点击 Dock 图标时重新打开主窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            Self.showMainWindow()
        }
        return true
    }

    /// 显示主窗口（支持隐藏/最小化的窗口恢复）
    static func showMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = mainWindow {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        }
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
        Window("Clawgirl", id: "main") {
            ContentView()
                // 将 chatManager 注入到视图层级，所有子视图均可通过 @EnvironmentObject 访问
                .environmentObject(chatManager)
        }
        // 隐藏窗口标题栏，实现沉浸式 UI 效果
        .windowStyle(.hiddenTitleBar)
        .commands {
            // 添加"语音"菜单栏菜单，方便用户通过菜单触发语音输入
            // 注意：菜单栏快捷键显示为默认值，实际快捷键由 setupKeyMonitor() 中的自定义配置驱动
            CommandMenu("语音") {
                if chatManager.shortcutPushToTalk.isModifierOnly {
                    Button("语音输入 (\(chatManager.shortcutPushToTalk.displayString))") {
                        NotificationCenter.default.post(name: .ctrlDPressed, object: nil)
                    }
                } else {
                    Button("语音输入") {
                        NotificationCenter.default.post(name: .ctrlDPressed, object: nil)
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character(chatManager.shortcutPushToTalk.key)),
                        modifiers: chatManager.shortcutPushToTalk.swiftUIModifiers
                    )
                }
            }
        }

        // 菜单栏常驻图标（根据状态动态变化）
        MenuBarExtra {
            MenuBarView(chatManager: chatManager)
        } label: {
            MenuBarIconView(state: chatManager.state)
        }
    }
}

/// 菜单栏图标视图：根据 ChatState 动态切换图标
struct MenuBarIconView: View {
    let state: ChatState

    var body: some View {
        switch state {
        case .idle:
            Image("MenuBarIcon")
                .renderingMode(.template)
        case .listening:
            Image(systemName: "mic.fill")
                .symbolRenderingMode(.monochrome)
        case .thinking:
            Image(systemName: "ellipsis.circle.fill")
                .symbolRenderingMode(.monochrome)
        case .speaking:
            Image(systemName: "speaker.wave.2.fill")
                .symbolRenderingMode(.monochrome)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.monochrome)
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

        if chatManager.shortcutPushToTalk.isModifierOnly {
            Button("语音输入 (\(chatManager.shortcutPushToTalk.displayString))") {
                openMainWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.post(name: .ctrlDPressed, object: nil)
                }
            }
        } else {
            Button("语音输入") {
                openMainWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.post(name: .ctrlDPressed, object: nil)
                }
            }
            .keyboardShortcut(
                KeyEquivalent(Character(chatManager.shortcutPushToTalk.key)),
                modifiers: chatManager.shortcutPushToTalk.swiftUIModifiers
            )
        }

        if chatManager.shortcutVoiceWake.isModifierOnly {
            Toggle("语音唤醒 (\(chatManager.shortcutVoiceWake.displayString))", isOn: $chatManager.voiceWakeEnabled)
        } else {
            Toggle("语音唤醒", isOn: $chatManager.voiceWakeEnabled)
                .keyboardShortcut(
                    KeyEquivalent(Character(chatManager.shortcutVoiceWake.key)),
                    modifiers: chatManager.shortcutVoiceWake.swiftUIModifiers
                )
        }

        Divider()

        Button("退出 Clawgirl") {
            NSApplication.shared.terminate(nil)
        }
    }

    private func openMainWindow() {
        AppDelegate.showMainWindow()
    }
}
