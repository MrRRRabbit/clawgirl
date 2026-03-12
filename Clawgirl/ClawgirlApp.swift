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

import SwiftUI

/// Clawgirl App 入口结构体
/// 使用 SwiftUI 的 App 协议定义应用程序生命周期
@main
struct ClawgirlApp: App {
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
    }
}
