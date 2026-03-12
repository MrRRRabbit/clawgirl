// ContentView.swift
// Clawgirl
//
// 文件用途：Clawgirl 的主 UI 视图，包含完整的用户界面布局和所有状态动画。
// 核心功能：
//   1. ContentView：主容器视图，组织头像、状态动画、聊天记录、输入区域
//   2. StateAnimationView：根据 ChatState 切换不同动画效果（水波/波形/弹跳点/声浪/错误脉冲）
//   3. AvatarView / LobsterAvatarView：龙虾娘头像，根据状态切换帧图片并实现眨眼动画
//   4. ChatHistoryView / MessageBubble：聊天记录列表与单条消息气泡
//   5. InputAreaView：文字输入、图片附件、语音按钮（按住录音/松开发送）
//   6. SettingsPopoverView：设置面板（唤醒词、网关连接、模型路径）
//   7. ShortcutHelpView：快捷键帮助弹窗

import SwiftUI
import Combine
import UniformTypeIdentifiers
import AppKit

// MARK: - ContentView

/// 主视图：应用程序的根 UI，包含背景渐变、头像区域、控制栏和聊天区域
struct ContentView: View {
    /// 从环境中获取全局 ChatManager，驱动所有状态更新
    @EnvironmentObject var chatManager: ChatManager

    /// 鼠标悬停状态，用于触发头像轻微放大动画
    @State private var isHovering = false

    /// 全局键盘事件监听器（NSEvent monitor）的句柄，用于注销时移除
    @State private var keyMonitor: Any?

    /// 控制唤醒词设置 Popover 的显示/隐藏
    @State private var showWakeWordSettings = false

    /// 控制快捷键帮助 Sheet 的显示/隐藏
    @State private var showShortcutHelp = false
    
    /// 根据模型加载状态生成对应的提示文字
    /// 两个模型都未加载时显示通用提示，否则指出具体是哪个模型在加载
    private var modelLoadingText: String {
        if !chatManager.isWakeModelLoaded && !chatManager.isMainModelLoaded {
            return "正在加载语音模型..."
        } else if !chatManager.isWakeModelLoaded {
            return "正在加载唤醒词模型..."
        } else {
            return "正在加载语音识别模型..."
        }
    }
    
    var body: some View {
        ZStack {
            // 背景：多色渐变，颜色随 ChatState 变化（通过 primaryColor 驱动）
            LinearGradient(
                colors: [
                    chatManager.state.primaryColor.opacity(0.25),
                    Color(hex: "0a1628"),
                    Color(hex: "0d2b45"),
                    Color(hex: "1a4a6e"),
                    Color(hex: "2980b9").opacity(0.6)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // 头像区域：龙虾娘头像，鼠标悬停时放大 5%
                AvatarView(state: chatManager.state)
                    .frame(width: 300, height: 300)
                    .padding(.top, 20)
                    .padding(.bottom, 0)
                    .scaleEffect(isHovering ? 1.05 : 1.0, anchor: .center)
                
                // 状态动画指示器：水波/波形/弹跳点/声浪/错误脉冲
                StateAnimationView(state: chatManager.state)
                    .frame(height: 30)
                    .padding(.bottom, 4)
                
                // 模型加载进度指示器：仅在模型尚未加载完成时显示
                if !chatManager.isWakeModelLoaded || !chatManager.isMainModelLoaded {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .progressViewStyle(.circular)
                        Text(modelLoadingText)
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.bottom, 4)
                }
                
                // 控制栏：声音选择、语音唤醒开关、设置按钮、快捷键帮助
                HStack {
                    Spacer()
                    // 声音图标
                    Image(systemName: "speaker.wave.2")
                        .foregroundColor(.white.opacity(0.8))
                        .font(.caption)
                    // 中文 TTS 声音选择下拉菜单
                    Picker(selection: $chatManager.zhVoiceId, label: Text("")) {
                        ForEach(chatManager.zhVoiceOptions) { voice in
                            Text(voice.name).tag(voice.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(minWidth: 120, idealWidth: 160, maxWidth: 200, minHeight: 24, idealHeight: 28, maxHeight: 32)
                    .colorScheme(.dark)

                    // 语音唤醒开关按钮：耳朵图标，开启时高亮
                    Button(action: {
                        chatManager.voiceWakeEnabled.toggle()
                    }) {
                        Image(systemName: chatManager.voiceWakeEnabled ? "ear.fill" : "ear")
                            .font(.system(size: 14))
                            .foregroundColor(chatManager.voiceWakeEnabled ? Color(hex: "48d1cc") : .white.opacity(0.5))
                            .frame(width: 28, height: 28)
                            .background(
                                Circle().fill(chatManager.voiceWakeEnabled ? Color(hex: "48d1cc").opacity(0.2) : Color.white.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(chatManager.voiceWakeEnabled ? "语音唤醒已开启" : "语音唤醒已关闭")
                    
                    // 设置按钮：齿轮图标，点击弹出 SettingsPopoverView
                    Button(action: { showWakeWordSettings.toggle() }) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("设置")
                    .popover(isPresented: $showWakeWordSettings) {
                        SettingsPopoverView()
                            .environmentObject(chatManager)
                    }
                    
                    // 快捷键帮助按钮：键盘图标，点击弹出快捷键一览
                    Button(action: { showShortcutHelp.toggle() }) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("快捷键 (⌘/)")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.3))
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                
                // 聊天记录列表
                ChatHistoryView(messages: chatManager.messages)
                    .padding(.horizontal, 12)
                
                // 输入区域：文字输入框 + 麦克风按钮 + 发送按钮 + 图片附件
                InputAreaView()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        // 鼠标悬停时触发头像放大动画
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
        .onAppear { setupKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
        // 接收来自 Notification 的快捷键帮助显示请求
        .onReceive(NotificationCenter.default.publisher(for: .showShortcutHelp)) { _ in
            showShortcutHelp.toggle()
        }
        .sheet(isPresented: $showShortcutHelp) {
            ShortcutHelpView()
        }
    }
    
    /// 注册全局键盘事件监听器（仅监听本窗口内的键盘事件）
    /// 支持以下快捷键：
    ///   - ⌘D：语音输入（push-to-talk）
    ///   - ⌘E：切换语音唤醒开关
    ///   - ⌘/：显示快捷键帮助
    private func setupKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) && !flags.contains(.control) && !flags.contains(.option) {
                // ⌘D：语音输入（keyCode 2 = D 键）
                if event.keyCode == 2 {
                    print("[KeyMonitor] Cmd+D detected, posting notification")
                    NotificationCenter.default.post(name: .ctrlDPressed, object: nil)
                    return nil  // 消费事件，不再传递
                }
                // ⌘E：切换语音唤醒（keyCode 14 = E 键）
                if event.keyCode == 14 {
                    NotificationCenter.default.post(name: .toggleVoiceWake, object: nil)
                    return nil
                }
                // ⌘/：显示快捷键帮助（keyCode 44 = / 键）
                if event.keyCode == 44 {
                    NotificationCenter.default.post(name: .showShortcutHelp, object: nil)
                    return nil
                }
            }
            return event
        }
    }
    
    /// 注销键盘事件监听器，在视图消失时调用以避免内存泄漏
    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

/// Notification 扩展：定义 Clawgirl 内部使用的自定义通知名称
extension Notification.Name {
    /// 语音输入触发（⌘D 或菜单"语音输入"）
    static let ctrlDPressed = Notification.Name("ctrlDPressed")
    /// 切换语音唤醒开关（⌘E）
    static let toggleVoiceWake = Notification.Name("toggleVoiceWake")
    /// 显示快捷键帮助（⌘/）
    static let showShortcutHelp = Notification.Name("showShortcutHelp")
}

// MARK: - StateAnimationView

/// 状态动画分发视图：根据当前 ChatState 选择并显示对应的动画组件
struct StateAnimationView: View {
    /// 当前应用状态，驱动动画切换
    let state: ChatState
    
    var body: some View {
        switch state {
        case .idle:
            IdleRippleView()       // 空闲：平静水波纹
        case .listening:
            ListeningWaveView()    // 监听中：随机高度的音频柱
        case .thinking:
            ThinkingDotsView()     // 思考中：三点弹跳动画
        case .speaking:
            SpeakingBarsView()     // 说话中：脉冲声浪柱
        case .error:
            ErrorPulseView()       // 错误：红色脉冲圆点
        }
    }
}

/// 空闲状态动画：三层向外扩散的椭圆水波纹，模拟平静水面
struct IdleRippleView: View {
    /// 控制动画开始（false → true 触发扩散）
    @State private var animate = false
    
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Ellipse()
                    .stroke(Color(hex: "5bbce4").opacity(animate ? 0 : 0.3), lineWidth: 1.5)
                    .frame(width: animate ? 160 : 40, height: animate ? 20 : 5)
                    .animation(
                        .easeOut(duration: 3.0)
                        .repeatForever(autoreverses: false)
                        .delay(Double(i) * 1.0),  // 三个波纹错开 1 秒依次扩散
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}

/// 监听状态动画：7 根随机高度的青绿色音频柱，模拟实时声波
struct ListeningWaveView: View {
    /// 7 根柱子的相对高度（0.2~1.0），由定时器随机更新
    @State private var levels: [CGFloat] = Array(repeating: 0.3, count: 7)
    /// 更新定时器，每 0.12 秒刷新一次柱子高度
    @State private var timer: Timer?
    
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<7, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: "48d1cc"))
                    .frame(width: 4, height: levels[i] * 24)
                    .animation(.easeInOut(duration: 0.15), value: levels[i])
            }
        }
        .onAppear { startAnimating() }
        .onDisappear { timer?.invalidate() }
    }
    
    /// 启动定时器，周期性随机更新每根柱子的高度以产生动态效果
    private func startAnimating() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
            for i in 0..<levels.count {
                levels[i] = CGFloat.random(in: 0.2...1.0)
            }
        }
    }
}

/// 思考状态动画：三个暖沙色圆点依次上下弹跳
struct ThinkingDotsView: View {
    /// 控制弹跳偏移量切换
    @State private var animate = false
    
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color(hex: "f0c27f"))
                    .frame(width: 8, height: 8)
                    .offset(y: animate ? -6 : 2)
                    .animation(
                        .easeInOut(duration: 0.5)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.15),  // 三个点错开 0.15 秒形成波浪感
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}

/// 说话状态动画：5 根珊瑚色声浪柱，高度脉冲变化，模拟语音输出
struct SpeakingBarsView: View {
    /// 控制柱子高度在最小值和预设高度之间切换
    @State private var animate = false
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: "ff6b6b"))
                    // 各柱子目标高度不同，形成不规则声浪感
                    .frame(width: 5, height: animate ? CGFloat([18, 24, 14, 22, 16][i]) : 6)
                    .animation(
                        .easeInOut(duration: 0.4)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.1),  // 五根柱子错开 0.1 秒
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}

/// 错误状态动画：红色圆点脉冲缩放，提示发生错误
struct ErrorPulseView: View {
    /// 控制缩放和透明度变化
    @State private var animate = false
    
    var body: some View {
        Circle()
            .fill(Color(hex: "e74c3c"))
            .frame(width: 10, height: 10)
            .scaleEffect(animate ? 1.5 : 1.0)
            .opacity(animate ? 0.5 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: animate)
            .onAppear { animate = true }
    }
}

// MARK: - AvatarView

/// 头像容器视图：在头像背后叠加径向发光效果
struct AvatarView: View {
    /// 当前状态，决定发光颜色和头像帧
    let state: ChatState
    
    var body: some View {
        ZStack {
            // 径向渐变发光背景，颜色跟随状态变化
            Circle()
                .fill(
                    RadialGradient(
                        colors: [state.glowColor.opacity(0.4), .clear],
                        center: .center,
                        startRadius: 20,
                        endRadius: 150
                    )
                )
                .frame(width: 280, height: 280)
            
            // 龙虾娘头像（含眨眼和说话帧动画）
            LobsterAvatarView(state: state)
        }
    }
}

// MARK: - ImageCache

/// 图片缓存：避免重复从 Bundle 加载相同资源图片，提升渲染性能
private class ImageCache {
    /// 全局单例
    static let shared = ImageCache()
    /// 内存缓存字典：图片名 → NSImage
    private var cache: [String: NSImage] = [:]
    
    /// 获取指定名称的图片，优先返回内存缓存，未命中则从 Bundle 加载
    /// - Parameter name: 图片资源名（不含扩展名，Xcode 已将 .png 复制到 Resources/）
    /// - Returns: 找到的 NSImage，或 nil（资源不存在时）
    func image(named name: String) -> NSImage? {
        if let cached = cache[name] {
            return cached
        }
        
        // 从 Bundle 资源目录加载 PNG 文件
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            cache[name] = img
            return img
        }
        
        return nil
    }
}

// MARK: - LobsterAvatarView

/// 龙虾娘头像视图：根据 ChatState 显示对应帧图片，实现眨眼和说话动画
struct LobsterAvatarView: View {
    /// 当前状态，决定显示哪张帧图片
    let state: ChatState

    /// 是否处于眨眼帧（true = 显示 idle_blink 图）
    @State private var isBlinking = false

    /// 眨眼触发定时器：每 3 秒尝试触发一次眨眼（仅 idle 状态下实际眨眼）
    @State private var blinkTimer = Timer.publish(every: 3.0, on: .main, in: .common).autoconnect()

    /// 说话帧计数器：在 0/1 之间切换，驱动 speaking_1/speaking_2 帧交替
    @State private var speakingFrame = 0

    /// 说话帧切换定时器：每 0.3 秒切换一次帧，模拟嘴部动作
    @State private var speakingTimer = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()
    
    /// 根据当前状态和动画帧计算应显示的图片名称
    var currentImageName: String {
        switch state {
        case .idle:
            // 空闲时偶尔眨眼
            return isBlinking ? "idle_blink" : "idle"
        case .listening:
            return "listening"
        case .thinking:
            return "thinking"
        case .speaking:
            // 说话时在两帧之间交替，模拟嘴部开合
            return speakingFrame % 2 == 0 ? "speaking_1" : "speaking_2"
        case .error:
            return "idle"
        }
    }
    
    var body: some View {
        Group {
            if let img = ImageCache.shared.image(named: currentImageName) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.none)  // 像素风格不插值，保持锐利边缘
                    .scaledToFit()
                    .frame(width: 200, height: 200)
            } else {
                // 图片资源缺失时的 emoji 降级显示
                Text("🦞")
                    .font(.system(size: 100))
            }
        }
        // 处理眨眼定时器：仅在 idle 状态下触发眨眼动画（开眼 → 闭眼 0.15s → 开眼 0.15s）
        .onReceive(blinkTimer) { _ in
            guard state == .idle else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                isBlinking = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isBlinking = false
                }
            }
        }
        // 处理说话帧定时器：仅在 speaking 状态下推进帧计数
        .onReceive(speakingTimer) { _ in
            guard state == .speaking else { return }
            speakingFrame += 1
        }
    }
}

// MARK: - ChatHistoryView

/// 聊天记录列表：自动滚动到最新消息
struct ChatHistoryView: View {
    /// 要显示的消息数组（来自 ChatManager）
    let messages: [ChatMessage]
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.vertical, 8)
            }
            // 消息数量变化时自动滚动到最新消息
            .onChange(of: messages.count) {
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(minHeight: 100, maxHeight: .infinity)
    }
}

// MARK: - MessageBubble

/// 单条消息气泡：用户消息靠右（蓝色），AI 消息靠左（半透明白色）
/// 支持显示附带的图片附件
struct MessageBubble: View {
    /// 要渲染的消息数据
    let message: ChatMessage
    
    var body: some View {
        HStack {
            // 用户消息：左侧 Spacer 推到右边
            if message.isUser { Spacer(minLength: 60) }
            
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                // 如有图片附件，在文字上方显示图片预览
                if !message.images.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(message.images) { img in
                            if let nsImage = NSImage(data: img.data) {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: 120, maxHeight: 120)
                                    .cornerRadius(8)
                            }
                        }
                    }
                }
                
                // 消息文字气泡
                Text(message.content)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .textSelection(.enabled)  // 允许用户选择复制文字
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(message.isUser
                                  ? Color(hex: "2980b9").opacity(0.45)  // 用户：深蓝半透明
                                  : Color.white.opacity(0.12))           // AI：浅白半透明
                    )
            }
            
            // AI 消息：右侧 Spacer 推到左边
            if !message.isUser { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - InputAreaView

/// 输入区域视图：包含图片附件预览、文字输入框、语音按钮和发送按钮
struct InputAreaView: View {
    /// 从环境获取 ChatManager，用于发送消息和获取录音状态
    @EnvironmentObject var chatManager: ChatManager

    /// 当前文字输入内容
    @State private var inputText = ""

    /// 已选择的图片附件列表
    @State private var selectedImages: [ImageAttachment] = []

    /// 粘贴事件监听器句柄
    @State private var pasteMonitor: Any?
    
    var body: some View {
        VStack(spacing: 8) {
            // 图片附件预览条（仅在有附件时显示）
            if !selectedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(selectedImages) { img in
                            ZStack(alignment: .topTrailing) {
                                // 图片缩略图
                                if let nsImage = NSImage(data: img.data) {
                                    Image(nsImage: nsImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 60, height: 60)
                                        .clipped()
                                        .cornerRadius(8)
                                }
                                // 删除附件按钮（右上角 ×）
                                Button(action: {
                                    selectedImages.removeAll { $0.id == img.id }
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundColor(.white)
                                        .background(Circle().fill(Color.black.opacity(0.5)))
                                }
                                .buttonStyle(.plain)
                                .offset(x: 4, y: -4)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(height: 68)
            }
            
            // 输入行：附件按钮 + 文字输入框 + 麦克风 + 发送
            HStack(spacing: 8) {
                // 附件选择按钮：打开文件选择器添加图片
                Button(action: pickImages) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.8))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
                
                // 文字输入框（支持多行，Shift+Enter 换行，Enter 发送）
                ZStack(alignment: .leading) {
                    // Placeholder 文字（TextEditor 没有内置 placeholder，用 ZStack 实现）
                    if inputText.isEmpty {
                        Text("输入消息或发送图片...")
                            .foregroundColor(.white.opacity(0.4))
                            .font(.system(size: 14))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                    TextEditor(text: $inputText)
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .frame(minHeight: 36, maxHeight: 100)
                        .fixedSize(horizontal: false, vertical: true)
                        .onKeyPress(.return, phases: .down) { _ in
                            if NSEvent.modifierFlags.contains(.shift) {
                                return .ignored  // Shift+Enter：允许换行
                            } else {
                                sendCurrentMessage()
                                return .handled  // Enter：发送消息并消费事件
                            }
                        }
                }
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.white.opacity(0.12))
                )
                
                // 麦克风按钮：长按开始录音，松开停止并发送
                // 使用 LongPressGesture + DragGesture 组合实现 push-to-talk 效果
                Image(systemName: chatManager.state == .listening ? "mic.circle.fill" : "mic.fill")
                    .font(.system(size: chatManager.state == .listening ? 22 : 18))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(chatManager.state == .listening ? Color(hex: "48d1cc") : Color(hex: "ff6b6b")))
                    .contentShape(Circle())
                    .gesture(
                        // 长按手势（最短 0.1s 触发）：开始录音
                        LongPressGesture(minimumDuration: 0.1)
                            .onEnded { _ in
                                if chatManager.state != .listening {
                                    chatManager.startListening()
                                }
                            }
                    )
                    .simultaneousGesture(
                        // 拖拽手势（松手时触发 onEnded）：停止录音并等待转写结果
                        DragGesture(minimumDistance: 0)
                            .onEnded { _ in
                                if chatManager.state == .listening {
                                    chatManager.stopListening()
                                    Task { @MainActor in
                                        // 轮询等待 WhisperKit 转写完成（最多 10 秒）
                                        for _ in 0..<20 {
                                            try? await Task.sleep(for: .milliseconds(500))
                                            if !chatManager.currentTranscription.isEmpty {
                                                break
                                            }
                                        }
                                        // 转写完成后自动填入输入框并发送
                                        if !chatManager.currentTranscription.isEmpty {
                                            inputText = chatManager.currentTranscription
                                            chatManager.currentTranscription = ""
                                            sendCurrentMessage()
                                        }
                                    }
                                }
                            }
                    )
                
                // 发送按钮：无内容时半透明禁用
                Button(action: sendCurrentMessage) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white.opacity(inputText.isEmpty && selectedImages.isEmpty ? 0.4 : 1.0))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .disabled(inputText.isEmpty && selectedImages.isEmpty)
            }
        }
        .onAppear { setupPasteMonitor() }
        .onDisappear { removePasteMonitor() }
        // 接收 ⌘D 快捷键通知：切换录音状态
        .onReceive(NotificationCenter.default.publisher(for: .ctrlDPressed)) { _ in
            handleCtrlD()
        }
        // 接收 ⌘E 通知：切换语音唤醒开关
        .onReceive(NotificationCenter.default.publisher(for: .toggleVoiceWake)) { _ in
            chatManager.voiceWakeEnabled.toggle()
        }
    }
    
    /// 发送当前消息（文字 + 图片附件），发送后清空输入框
    private func sendCurrentMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !selectedImages.isEmpty else { return }
        
        chatManager.sendMessage(text, images: selectedImages)
        inputText = ""
        selectedImages = []
    }
    
    /// 打开系统文件选择对话框，选取图片作为附件
    /// 支持格式：PNG、JPEG、GIF、WebP
    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        
        if panel.runModal() == .OK {
            for url in panel.urls {
                if let data = try? Data(contentsOf: url) {
                    let mimeType = mimeTypeForURL(url)
                    let attachment = ImageAttachment(data: data, fileName: url.lastPathComponent, mimeType: mimeType)
                    selectedImages.append(attachment)
                }
            }
        }
    }
    
    /// 根据文件扩展名返回对应的 MIME 类型字符串
    /// - Parameter url: 图片文件 URL
    /// - Returns: MIME 类型字符串，未知格式默认返回 "image/png"
    private func mimeTypeForURL(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }
    
    /// 注册粘贴事件监听器（监听 ⌘V 键），用于支持从剪贴板粘贴图片
    private func setupPasteMonitor() {
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 检测 ⌘V 粘贴快捷键
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "v" {
                if handlePasteImages() {
                    return nil  // 成功粘贴图片时消费事件，阻止文字粘贴
                }
            }
            return event
        }
    }
    
    /// 处理 ⌘D 快捷键：切换录音状态
    /// - 已在录音：停止录音并等待转写结果后发送
    /// - 未在录音：开始录音
    private func handleCtrlD() {
        print("[CtrlD] handleCtrlD called, state=\(chatManager.state)")
        if chatManager.state == .listening {
            // 停止录音
            chatManager.stopListening()
            print("[CtrlD] Stopped listening, transcription='\(chatManager.currentTranscription.prefix(30))'")
            // 等待 WhisperKit 转写完成（最多等 10 秒）
            Task { @MainActor in
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if !chatManager.currentTranscription.isEmpty {
                        break
                    }
                }
                print("[CtrlD] After wait, transcription='\(chatManager.currentTranscription.prefix(30))'")
                if !chatManager.currentTranscription.isEmpty {
                    inputText = chatManager.currentTranscription
                    chatManager.currentTranscription = ""
                    sendCurrentMessage()
                }
            }
        } else {
            // 开始录音
            print("[CtrlD] Starting listening...")
            chatManager.startListening()
        }
    }
    
    /// 注销粘贴事件监听器
    private func removePasteMonitor() {
        if let monitor = pasteMonitor {
            NSEvent.removeMonitor(monitor)
            pasteMonitor = nil
        }
    }
    
    /// 从剪贴板读取图片并添加为附件
    /// 支持直接复制的图片数据（PNG/TIFF）及包含图片 URL 的文件引用
    /// - Returns: 是否成功从剪贴板获取到图片
    private func handlePasteImages() -> Bool {
        let pasteboard = NSPasteboard.general
        
        guard let types = pasteboard.types else { return false }
        
        // 优先检查剪贴板中的直接图片数据（如截图、浏览器复制的图片）
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png, .tiff,
            NSPasteboard.PasteboardType("public.image")
        ]
        
        for imageType in imageTypes {
            if types.contains(imageType), let data = pasteboard.data(forType: imageType) {
                // 验证数据确实是有效图片
                guard NSImage(data: data) != nil else { continue }
                
                let mimeType = imageType == .png ? "image/png" : "image/png"
                let attachment = ImageAttachment(
                    data: data,
                    fileName: "clipboard.png",
                    mimeType: mimeType
                )
                selectedImages.append(attachment)
                return true
            }
        }
        
        // 其次尝试从文件 URL 中读取图片（如 Finder 复制的图片文件）
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]) as? [URL] {
            for url in urls {
                if let data = try? Data(contentsOf: url) {
                    let attachment = ImageAttachment(
                        data: data,
                        fileName: url.lastPathComponent,
                        mimeType: mimeTypeForURL(url)
                    )
                    selectedImages.append(attachment)
                }
            }
            return !urls.isEmpty
        }
        
        return false
    }
}

// MARK: - SettingsPopoverView

/// 设置面板视图（Popover）：提供三个配置区域
/// 1. 唤醒词管理：添加/删除/重置唤醒词列表
/// 2. 网关连接：WebSocket 地址、Token、会话 Key 及连接状态
/// 3. 模型路径：WhisperKit CoreML 模型目录选择及加载状态
struct SettingsPopoverView: View {
    @EnvironmentObject var chatManager: ChatManager

    /// 新唤醒词输入框的临时内容
    @State private var newWord = ""

    /// 是否正在编辑模型路径（当前未使用，预留）
    @State private var editingPath = false

    /// 模型路径临时编辑值（当前未使用，预留）
    @State private var tempPath = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // ── 唤醒词区域 ──
            Text("唤醒词")
                .font(.headline)
            
            // 唤醒词列表（可滚动）
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(chatManager.wakeWordsDisplay, id: \.self) { word in
                        HStack {
                            Text(word)
                                .font(.system(size: 13))
                            Spacer()
                            // 删除单个唤醒词
                            Button(action: { chatManager.removeWakeWord(word) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                    }
                }
            }
            .frame(maxHeight: 150)
            
            // 添加新唤醒词输入行
            HStack {
                TextField("添加唤醒词...", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .onSubmit { addWord() }
                
                Button("添加") { addWord() }
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            
            // 重置为默认唤醒词列表
            Button("恢复默认唤醒词") {
                chatManager.resetWakeWords()
            }
            .font(.caption)
            .foregroundColor(.secondary)
            
            Divider()
            
            // ── 网关连接区域 ──
            Text("网关连接")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 6) {
                // WebSocket 服务器地址
                HStack {
                    Text("地址")
                        .font(.caption)
                        .frame(width: 40, alignment: .leading)
                    TextField("ws://127.0.0.1:18789", text: $chatManager.gatewayURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                
                // 认证 Token（密文输入框）
                HStack {
                    Text("Token")
                        .font(.caption)
                        .frame(width: 40, alignment: .leading)
                    SecureField("Gateway Token", text: $chatManager.gatewayToken)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                
                // 会话 Key（指定路由到哪个 AI session）
                HStack {
                    Text("会话")
                        .font(.caption)
                        .frame(width: 40, alignment: .leading)
                    TextField("main", text: $chatManager.sessionKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                
                // 当前连接状态指示灯
                HStack(spacing: 4) {
                    Circle()
                        .fill(chatManager.isConnected ? Color.green : Color.red)
                        .frame(width: 6, height: 6)
                    Text(chatManager.isConnected ? "已连接" : "未连接")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                // 提示：部分设置需重启生效
                Text("修改后需重启 App 生效")
                    .font(.caption2)
                    .foregroundColor(.orange.opacity(0.8))
            }
            
            Divider()
            
            // ── 模型路径区域 ──
            Text("模型路径")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 6) {
                // 当前路径显示（截断中间部分避免过长）
                Text(chatManager.modelBasePath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                
                HStack {
                    // 选择自定义模型文件夹
                    Button("选择文件夹...") {
                        chooseModelFolder()
                    }
                    .font(.caption)
                    
                    // 恢复默认路径
                    Button("恢复默认") {
                        chatManager.modelBasePath = ChatManager.defaultModelPath
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                
                // 两个模型的加载状态指示灯
                HStack(spacing: 4) {
                    Circle()
                        .fill(chatManager.isWakeModelLoaded ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text("唤醒词模型")
                        .font(.caption2)
                    
                    Circle()
                        .fill(chatManager.isMainModelLoaded ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                        .padding(.leading, 8)
                    Text("语音识别模型")
                        .font(.caption2)
                }
                .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(width: 320)
    }
    
    /// 将输入框中的新唤醒词添加到列表，成功后清空输入框
    private func addWord() {
        chatManager.addWakeWord(newWord)
        newWord = ""
    }
    
    /// 打开目录选择对话框，让用户选择 WhisperKit 模型所在文件夹
    private func chooseModelFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择 WhisperKit CoreML 模型所在的文件夹"
        panel.prompt = "选择"
        
        if panel.runModal() == .OK, let url = panel.url {
            chatManager.modelBasePath = url.path
        }
    }
}

// MARK: - ShortcutHelpView

/// 快捷键帮助弹窗：以表格形式列出所有可用快捷键及其说明
struct ShortcutHelpView: View {
    @Environment(\.dismiss) private var dismiss
    
    /// 快捷键列表：(键位, 功能说明)
    private let shortcuts: [(key: String, desc: String)] = [
        ("⌘ D", "语音输入（按住录音，松开发送）"),
        ("⌘ E", "开启/关闭唤醒词监听"),
        ("⌘ V", "粘贴图片"),
        ("⌘ /", "显示快捷键帮助"),
        ("Enter", "发送文字消息"),
        ("Shift + Enter", "换行"),
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题行 + 关闭按钮
            HStack {
                Text("⌨️ 快捷键")
                    .font(.title2.bold())
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            
            // 快捷键列表行
            VStack(spacing: 8) {
                ForEach(shortcuts, id: \.key) { shortcut in
                    HStack {
                        // 键位标签（等宽，便于对齐）
                        Text(shortcut.key)
                            .font(.system(size: 13, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)))
                            .frame(width: 120, alignment: .center)
                        
                        // 功能说明
                        Text(shortcut.desc)
                            .font(.system(size: 13))
                        
                        Spacer()
                    }
                }
            }
            
            Spacer()
            
            // 底部提示：唤醒词使用方法
            Text("提示：说唤醒词（默认\"小虾\"）可免手动操作，直接语音对话")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(20)
        .frame(width: 360, height: 300)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(ChatManager())
        .frame(width: 400, height: 700)
}
