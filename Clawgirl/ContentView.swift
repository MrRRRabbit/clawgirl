import SwiftUI
import Combine
import UniformTypeIdentifiers
import AppKit

// MARK: - ContentView

struct ContentView: View {
    @EnvironmentObject var chatManager: ChatManager
    @State private var isHovering = false
    @State private var keyMonitor: Any?
    @State private var showWakeWordSettings = false
    @State private var showShortcutHelp = false
    
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
                // Avatar area
                AvatarView(state: chatManager.state)
                    .frame(width: 300, height: 300)
                    .padding(.top, 20)
                    .padding(.bottom, 0)
                    .scaleEffect(isHovering ? 1.05 : 1.0, anchor: .center)
                
                // State animation indicator
                StateAnimationView(state: chatManager.state)
                    .frame(height: 30)
                    .padding(.bottom, 4)
                
                // Model loading indicator
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
                
                // Voice picker
                HStack {
                    Spacer()
                    Image(systemName: "speaker.wave.2")
                        .foregroundColor(.white.opacity(0.8))
                        .font(.caption)
                    Picker(selection: $chatManager.zhVoiceId, label: Text("")) {
                        ForEach(chatManager.zhVoiceOptions) { voice in
                            Text(voice.name).tag(voice.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(minWidth: 120, idealWidth: 160, maxWidth: 200, minHeight: 24, idealHeight: 28, maxHeight: 32)
                    .colorScheme(.dark)

                    // Voice Wake toggle
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
                    
                    // Wake word settings
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
                    
                    // Shortcut help
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
                
                // Chat history
                ChatHistoryView(messages: chatManager.messages)
                    .padding(.horizontal, 12)
                
                // Input area
                InputAreaView()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
        .onAppear { setupKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
        .onReceive(NotificationCenter.default.publisher(for: .showShortcutHelp)) { _ in
            showShortcutHelp.toggle()
        }
        .sheet(isPresented: $showShortcutHelp) {
            ShortcutHelpView()
        }
    }
    
    private func setupKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) && !flags.contains(.control) && !flags.contains(.option) {
                // Cmd+D: Push-to-talk (keyCode 2 = D)
                if event.keyCode == 2 {
                    print("[KeyMonitor] Cmd+D detected, posting notification")
                    NotificationCenter.default.post(name: .ctrlDPressed, object: nil)
                    return nil
                }
                // Cmd+E: Toggle voice wake (keyCode 14 = E)
                if event.keyCode == 14 {
                    NotificationCenter.default.post(name: .toggleVoiceWake, object: nil)
                    return nil
                }
                // Cmd+/: Show shortcut help (keyCode 44 = /)
                if event.keyCode == 44 {
                    NotificationCenter.default.post(name: .showShortcutHelp, object: nil)
                    return nil
                }
            }
            return event
        }
    }
    
    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

extension Notification.Name {
    static let ctrlDPressed = Notification.Name("ctrlDPressed")
    static let toggleVoiceWake = Notification.Name("toggleVoiceWake")
    static let showShortcutHelp = Notification.Name("showShortcutHelp")
}

// MARK: - StateAnimationView

struct StateAnimationView: View {
    let state: ChatState
    
    var body: some View {
        switch state {
        case .idle:
            IdleRippleView()
        case .listening:
            ListeningWaveView()
        case .thinking:
            ThinkingDotsView()
        case .speaking:
            SpeakingBarsView()
        case .error:
            ErrorPulseView()
        }
    }
}

// Idle: Gentle water ripple
struct IdleRippleView: View {
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
                        .delay(Double(i) * 1.0),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}

// Listening: Audio wave bars (turquoise)
struct ListeningWaveView: View {
    @State private var levels: [CGFloat] = Array(repeating: 0.3, count: 7)
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
    
    private func startAnimating() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
            for i in 0..<levels.count {
                levels[i] = CGFloat.random(in: 0.2...1.0)
            }
        }
    }
}

// Thinking: Bouncing dots (warm sand)
struct ThinkingDotsView: View {
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
                        .delay(Double(i) * 0.15),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}

// Speaking: Pulsing sound bars (coral)
struct SpeakingBarsView: View {
    @State private var animate = false
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: "ff6b6b"))
                    .frame(width: 5, height: animate ? CGFloat([18, 24, 14, 22, 16][i]) : 6)
                    .animation(
                        .easeInOut(duration: 0.4)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.1),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}

// Error: Red pulse
struct ErrorPulseView: View {
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

struct AvatarView: View {
    let state: ChatState
    
    var body: some View {
        ZStack {
            // Glow effect behind avatar
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
            
            LobsterAvatarView(state: state)
        }
    }
}

// MARK: - ImageCache

private class ImageCache {
    static let shared = ImageCache()
    private var cache: [String: NSImage] = [:]
    
    func image(named name: String) -> NSImage? {
        if let cached = cache[name] {
            return cached
        }
        
        // Load from bundle resources (Xcode copies .png files into Resources/)
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            cache[name] = img
            return img
        }
        
        return nil
    }
}

// MARK: - LobsterAvatarView

struct LobsterAvatarView: View {
    let state: ChatState
    @State private var isBlinking = false
    @State private var blinkTimer = Timer.publish(every: 3.0, on: .main, in: .common).autoconnect()
    @State private var speakingFrame = 0
    @State private var speakingTimer = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()
    
    var currentImageName: String {
        switch state {
        case .idle:
            return isBlinking ? "idle_blink" : "idle"
        case .listening:
            return "listening"
        case .thinking:
            return "thinking"
        case .speaking:
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
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 200, height: 200)
            } else {
                // Fallback when images aren't available
                Text("🦞")
                    .font(.system(size: 100))
            }
        }
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
        .onReceive(speakingTimer) { _ in
            guard state == .speaking else { return }
            speakingFrame += 1
        }
    }
}

// MARK: - ChatHistoryView

struct ChatHistoryView: View {
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

struct MessageBubble: View {
    let message: ChatMessage
    
    var body: some View {
        HStack {
            if message.isUser { Spacer(minLength: 60) }
            
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                // Display attached images if any
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
                
                Text(message.content)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(message.isUser
                                  ? Color(hex: "2980b9").opacity(0.45)
                                  : Color.white.opacity(0.12))
                    )
            }
            
            if !message.isUser { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - InputAreaView

struct InputAreaView: View {
    @EnvironmentObject var chatManager: ChatManager
    @State private var inputText = ""
    @State private var selectedImages: [ImageAttachment] = []
    @State private var pasteMonitor: Any?
    
    var body: some View {
        VStack(spacing: 8) {
            // Image preview strip
            if !selectedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(selectedImages) { img in
                            ZStack(alignment: .topTrailing) {
                                if let nsImage = NSImage(data: img.data) {
                                    Image(nsImage: nsImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 60, height: 60)
                                        .clipped()
                                        .cornerRadius(8)
                                }
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
            
            // Input row
            HStack(spacing: 8) {
                // Attach image button
                Button(action: pickImages) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.8))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
                
                // Text field
                TextField("输入消息或发送图片...", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color.white.opacity(0.12))
                    )
                    .onSubmit {
                        sendCurrentMessage()
                    }
                
                // Mic button — press and hold to record, release to stop
                Image(systemName: chatManager.state == .listening ? "mic.circle.fill" : "mic.fill")
                    .font(.system(size: chatManager.state == .listening ? 22 : 18))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(chatManager.state == .listening ? Color(hex: "48d1cc") : Color(hex: "ff6b6b")))
                    .contentShape(Circle())
                    .gesture(
                        LongPressGesture(minimumDuration: 0.1)
                            .onEnded { _ in
                                if chatManager.state != .listening {
                                    chatManager.startListening()
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { _ in
                                if chatManager.state == .listening {
                                    chatManager.stopListening()
                                    Task { @MainActor in
                                        // Wait for WhisperKit transcription to complete
                                        // Poll until transcription appears or timeout (10s max)
                                        for _ in 0..<20 {
                                            try? await Task.sleep(for: .milliseconds(500))
                                            if !chatManager.currentTranscription.isEmpty {
                                                break
                                            }
                                        }
                                        if !chatManager.currentTranscription.isEmpty {
                                            inputText = chatManager.currentTranscription
                                            chatManager.currentTranscription = ""
                                            sendCurrentMessage()
                                        }
                                    }
                                }
                            }
                    )
                
                // Send button
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
        .onReceive(NotificationCenter.default.publisher(for: .ctrlDPressed)) { _ in
            handleCtrlD()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleVoiceWake)) { _ in
            chatManager.voiceWakeEnabled.toggle()
        }
    }
    
    private func sendCurrentMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !selectedImages.isEmpty else { return }
        
        chatManager.sendMessage(text, images: selectedImages)
        inputText = ""
        selectedImages = []
    }
    
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
    
    private func setupPasteMonitor() {
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Cmd+V paste handling
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "v" {
                if handlePasteImages() {
                    return nil  // Consume the event
                }
            }
            return event
        }
    }
    
    private func handleCtrlD() {
        print("[CtrlD] handleCtrlD called, state=\(chatManager.state)")
        if chatManager.state == .listening {
            // Already listening — stop and send
            chatManager.stopListening()
            print("[CtrlD] Stopped listening, transcription='\(chatManager.currentTranscription.prefix(30))'")
            // Wait for WhisperKit transcription to complete
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
            // Start listening
            print("[CtrlD] Starting listening...")
            chatManager.startListening()
        }
    }
    
    private func removePasteMonitor() {
        if let monitor = pasteMonitor {
            NSEvent.removeMonitor(monitor)
            pasteMonitor = nil
        }
    }
    
    private func handlePasteImages() -> Bool {
        let pasteboard = NSPasteboard.general
        
        // Check for image data on the pasteboard
        guard let types = pasteboard.types else { return false }
        
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png, .tiff,
            NSPasteboard.PasteboardType("public.image")
        ]
        
        for imageType in imageTypes {
            if types.contains(imageType), let data = pasteboard.data(forType: imageType) {
                // Verify it's actually an image
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
        
        // Check for file URLs that are images
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

struct SettingsPopoverView: View {
    @EnvironmentObject var chatManager: ChatManager
    @State private var newWord = ""
    @State private var editingPath = false
    @State private var tempPath = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Wake words section
            Text("唤醒词")
                .font(.headline)
            
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(chatManager.wakeWordsDisplay, id: \.self) { word in
                        HStack {
                            Text(word)
                                .font(.system(size: 13))
                            Spacer()
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
            
            HStack {
                TextField("添加唤醒词...", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .onSubmit { addWord() }
                
                Button("添加") { addWord() }
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            
            Button("恢复默认唤醒词") {
                chatManager.resetWakeWords()
            }
            .font(.caption)
            .foregroundColor(.secondary)
            
            Divider()
            
            // Connection section
            Text("网关连接")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("地址")
                        .font(.caption)
                        .frame(width: 40, alignment: .leading)
                    TextField("ws://127.0.0.1:18789", text: $chatManager.gatewayURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                
                HStack {
                    Text("Token")
                        .font(.caption)
                        .frame(width: 40, alignment: .leading)
                    SecureField("Gateway Token", text: $chatManager.gatewayToken)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                
                HStack {
                    Text("会话")
                        .font(.caption)
                        .frame(width: 40, alignment: .leading)
                    TextField("main", text: $chatManager.sessionKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                
                HStack(spacing: 4) {
                    Circle()
                        .fill(chatManager.isConnected ? Color.green : Color.red)
                        .frame(width: 6, height: 6)
                    Text(chatManager.isConnected ? "已连接" : "未连接")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Text("修改后需重启 App 生效")
                    .font(.caption2)
                    .foregroundColor(.orange.opacity(0.8))
            }
            
            Divider()
            
            // Model path section
            Text("模型路径")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 6) {
                Text(chatManager.modelBasePath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                
                HStack {
                    Button("选择文件夹...") {
                        chooseModelFolder()
                    }
                    .font(.caption)
                    
                    Button("恢复默认") {
                        chatManager.modelBasePath = ChatManager.defaultModelPath
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                
                // Model status
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
    
    private func addWord() {
        chatManager.addWakeWord(newWord)
        newWord = ""
    }
    
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

struct ShortcutHelpView: View {
    @Environment(\.dismiss) private var dismiss
    
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
            
            VStack(spacing: 8) {
                ForEach(shortcuts, id: \.key) { shortcut in
                    HStack {
                        Text(shortcut.key)
                            .font(.system(size: 13, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)))
                            .frame(width: 120, alignment: .center)
                        
                        Text(shortcut.desc)
                            .font(.system(size: 13))
                        
                        Spacer()
                    }
                }
            }
            
            Spacer()
            
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
