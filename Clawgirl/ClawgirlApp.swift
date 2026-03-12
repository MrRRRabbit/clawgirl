import SwiftUI

@main
struct ClawgirlApp: App {
    @StateObject private var chatManager = ChatManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(chatManager)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("语音") {
                Button("语音输入 (⌘D)") {
                    NotificationCenter.default.post(name: .ctrlDPressed, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)
            }
        }
    }
}
