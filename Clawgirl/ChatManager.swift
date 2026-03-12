// ChatManager.swift
// Clawgirl
//
// 文件用途：Clawgirl 核心业务逻辑，负责连接管理、聊天通信、语音识别和 TTS 播放。
// 核心功能：
//   1. ChatManager（@MainActor ObservableObject）：统一管理应用状态、消息列表、语音识别、TTS 和唤醒词
//   2. WebSocketConnection（actor）：处理与 OpenClaw Gateway 的 WebSocket 通信，
//      包括协议握手、消息发送/接收、流式响应分句和自动重连
//   3. TTS Pipeline：使用 AVSpeechSynthesizer 串行播放 AI 回复句子，避免重叠或截断
//   4. WhisperKit：本地语音转文字（支持大/小/基础/微型模型，自动降级）
//   5. VAD（Voice Activity Detection）：在语音唤醒流程中自动检测静音并停止录音
//   6. 幻听过滤：清理 Whisper 在静音/噪音中生成的假字幕

import Foundation
import AudioToolbox
import AVFoundation
import Combine
import CoreML
import CryptoKit
import os.log
import SwiftUI
import WhisperKit

private let ttsLog = Logger(subsystem: "com.clawd.avatar", category: "TTS")

// MARK: - Chat State

/// 应用程序状态枚举，驱动 UI 动画和背景颜色变化
enum ChatState: Equatable {
    /// 空闲：等待用户输入
    case idle
    /// 监听中：正在录音（麦克风激活）
    case listening
    /// 思考中：消息已发送，等待 AI 回复
    case thinking
    /// 说话中：TTS 正在播放 AI 回复
    case speaking
    /// 错误：发生异常，短暂显示后恢复 idle
    case error
    
    /// 各状态对应的主色调（用于背景渐变和状态指示器）
    var primaryColor: Color {
        switch self {
        case .idle: return Color(hex: "5bbce4")      // 海洋蓝
        case .listening: return Color(hex: "48d1cc")  // 中等绿松石
        case .thinking: return Color(hex: "f0c27f")   // 温暖沙色
        case .speaking: return Color(hex: "ff6b6b")   // 珊瑚红
        case .error: return Color(hex: "e74c3c")      // 错误红
        }
    }
    
    /// 各状态对应的次色调（深色版本，用于渐变底部）
    var secondaryColor: Color {
        switch self {
        case .idle: return Color(hex: "2980b9")       // 深海蓝
        case .listening: return Color(hex: "20b2aa")   // 浅海绿
        case .thinking: return Color(hex: "e6a95c")   // 深沙色
        case .speaking: return Color(hex: "e05555")   // 深珊瑚
        case .error: return Color(hex: "c0392b")      // 深红
        }
    }
    
    /// 发光颜色（与主色相同，用于头像背后的径向光晕）
    var glowColor: Color { primaryColor }
    /// 眼睛颜色（与主色相同，预留给头像眼部着色）
    var eyeColor: Color { primaryColor }
}

// MARK: - Image Attachment

/// 图片附件数据模型：携带原始图片数据及元信息
struct ImageAttachment: Equatable, Identifiable {
    /// 唯一标识符，用于列表渲染和删除操作
    let id = UUID()
    /// 图片原始二进制数据
    let data: Data
    /// 文件名（显示用，发送给 AI 时附带）
    let fileName: String
    /// MIME 类型（"image/png" / "image/jpeg" 等）
    let mimeType: String
}

// MARK: - Chat Message

/// 聊天消息数据模型
struct ChatMessage: Identifiable, Equatable {
    /// 唯一标识符（UUID），用于 ScrollView 定位
    let id = UUID()
    /// 消息文字内容
    let content: String
    /// true = 用户消息（右对齐蓝色气泡），false = AI 消息（左对齐白色气泡）
    let isUser: Bool
    /// 消息时间戳
    let timestamp: Date
    /// 附带的图片列表（仅用户消息可能有附件）
    let images: [ImageAttachment]
    
    init(content: String, isUser: Bool, images: [ImageAttachment] = []) {
        self.content = content
        self.isUser = isUser
        self.timestamp = Date()
        self.images = images
    }
}

// MARK: - Voice Option

/// TTS 声音选项，用于声音选择 Picker 列表
struct VoiceOption: Identifiable, Hashable {
    /// 声音唯一标识符（AVSpeechSynthesisVoice.identifier）
    let id: String
    /// 显示名称（含质量标签，如 "Tingting (Premium)"）
    let name: String
    /// AVSpeechSynthesisVoice identifier 字符串
    let identifier: String
    /// 语言代码（如 "zh-CN"）
    let language: String
    /// 声音质量（premium > enhanced > default）
    let quality: AVSpeechSynthesisVoiceQuality
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: VoiceOption, rhs: VoiceOption) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Chat Manager

/// Clawgirl 核心管理器：协调所有功能模块，向 SwiftUI 视图暴露状态
/// 运行在 @MainActor 上，@Published 属性的更新直接驱动 UI 刷新
@MainActor
class ChatManager: ObservableObject {
    // ── 实例唯一性控制 ──

    /// 全局最新实例 ID，确保同一时刻只有最新的 ChatManager 实例可以播放 TTS
    /// 解决 Xcode ExecuteSnippet 等场景下残留旧实例继续说话的问题
    private static var latestInstanceId: UUID?

    /// 当前实例的唯一 ID
    private let instanceId = UUID()

    // ── 已发布状态（驱动 UI） ──

    /// 当前应用状态（idle/listening/thinking/speaking/error）
    /// 状态变化时触发 handleStateChange 管理唤醒词检测器的暂停/恢复
    @Published var state: ChatState = .idle {
        didSet {
            handleStateChange(from: oldValue, to: state)
        }
    }

    /// 聊天消息历史列表，追加新消息时 UI 自动滚动到底部
    @Published var messages: [ChatMessage] = []

    /// 当前语音识别结果（临时），InputAreaView 读取后填入输入框并清空
    @Published var currentTranscription: String = ""

    /// WebSocket 连接状态，用于 UI 指示灯和发送前校验
    @Published var isConnected: Bool = false

    /// 唤醒词显示列表（UI 绑定），与 WakeWordDetector.wakeWords 保持同步
    @Published var wakeWordsDisplay: [String] = {
        if let saved = UserDefaults.standard.array(forKey: "wakeWords") as? [String], !saved.isEmpty {
            return saved
        }
        return WakeWordDetector.defaultWakeWords
    }()
    
    /// 添加一个唤醒词到列表（去重，同步到 WakeWordDetector）
    /// - Parameter word: 要添加的唤醒词（自动去除首尾空白）
    func addWakeWord(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !wakeWordsDisplay.contains(trimmed) else { return }
        wakeWordsDisplay.append(trimmed)
        wakeWordDetector.wakeWords = wakeWordsDisplay
    }
    
    /// 从列表中删除指定唤醒词（同步到 WakeWordDetector）
    /// - Parameter word: 要删除的唤醒词
    func removeWakeWord(_ word: String) {
        wakeWordsDisplay.removeAll { $0 == word }
        wakeWordDetector.wakeWords = wakeWordsDisplay
    }
    
    /// 将唤醒词列表重置为默认值（同步到 WakeWordDetector）
    func resetWakeWords() {
        wakeWordsDisplay = WakeWordDetector.defaultWakeWords
        wakeWordDetector.wakeWords = wakeWordsDisplay
    }
    
    /// 语音唤醒开关，持久化到 UserDefaults
    /// 开启时请求麦克风权限并启动 WakeWordDetector，关闭时停止检测
    @Published var voiceWakeEnabled: Bool = UserDefaults.standard.bool(forKey: "voiceWakeEnabled") {
        didSet {
            UserDefaults.standard.set(voiceWakeEnabled, forKey: "voiceWakeEnabled")
            if voiceWakeEnabled {
                // 先请求麦克风权限，获得授权后才启动检测
                Task {
                    let granted = await wakeWordDetector.requestMicrophonePermission()
                    guard granted else {
                        debugLog("[CM] ⚠️ 麦克风权限被拒绝")
                        await MainActor.run { self.voiceWakeEnabled = false }
                        return
                    }
                    await MainActor.run {
                        self.wakeWordDetector.isPaused = false
                        self.wakeWordDetector.startDetecting()
                    }
                }
            } else {
                // 关闭语音唤醒：停止检测并标记为暂停，防止自动恢复
                wakeWordDetector.stopDetecting()
                wakeWordDetector.isPaused = true
            }
        }
    }
    
    // ── 声音选择 ──

    /// 当前选择的中文 TTS 声音 identifier，持久化到 UserDefaults
    @Published var zhVoiceId: String = UserDefaults.standard.string(forKey: "zhVoiceId") ?? "com.apple.voice.compact.zh-CN.Tingting"

    /// 当前选择的英文 TTS 声音 identifier（暂未暴露给 UI）
    @Published var enVoiceId: String = "com.apple.voice.premium.en-AU.Matilda"

    /// 唤醒词模型是否已加载完成（控制加载指示器）
    @Published var isWakeModelLoaded: Bool = false

    /// 主语音识别模型是否已加载完成（控制加载指示器）
    @Published var isMainModelLoaded: Bool = false
    
    // ── 网关连接配置（持久化到 UserDefaults） ──

    /// WebSocket 服务器地址（如 ws://127.0.0.1:18789）
    @Published var gatewayURL: String = UserDefaults.standard.string(forKey: "gatewayURL") ?? "ws://127.0.0.1:18789" {
        didSet { UserDefaults.standard.set(gatewayURL, forKey: "gatewayURL") }
    }

    /// 认证 Token（从 openclaw.json 读取，可在设置中覆盖）
    @Published var gatewayToken: String = UserDefaults.standard.string(forKey: "gatewayToken") ?? "" {
        didSet { UserDefaults.standard.set(gatewayToken, forKey: "gatewayToken") }
    }

    /// 会话 Key：指定路由到 OpenClaw 哪个 session（默认 "main"）
    @Published var sessionKey: String = UserDefaults.standard.string(forKey: "sessionKey") ?? "main" {
        didSet { UserDefaults.standard.set(sessionKey, forKey: "sessionKey") }
    }
    
    /// WhisperKit CoreML 模型根目录（可在设置中自定义，持久化到 UserDefaults）
    @Published var modelBasePath: String = {
        if let saved = UserDefaults.standard.string(forKey: "modelBasePath"), !saved.isEmpty {
            return saved
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
            .path
    }() {
        didSet {
            UserDefaults.standard.set(modelBasePath, forKey: "modelBasePath")
        }
    }
    
    /// 默认模型路径（用于设置中"恢复默认"按钮）
    static var defaultModelPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
            .path
    }

    /// 系统中可用的中文/粤语 TTS 声音列表（按质量降序排列）
    var zhVoiceOptions: [VoiceOption] {
        var seen = Set<String>()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") || $0.language.hasPrefix("yue") }
            .filter { seen.insert($0.identifier).inserted }  // 去重
            .map { VoiceOption(id: $0.identifier, name: voiceDisplayName($0), identifier: $0.identifier, language: $0.language, quality: $0.quality) }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }  // 高质量声音优先
    }

    /// 系统中可用的英文 TTS 声音列表（按质量降序排列）
    var enVoiceOptions: [VoiceOption] {
        var seen = Set<String>()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .filter { seen.insert($0.identifier).inserted }
            .map { VoiceOption(id: $0.identifier, name: voiceDisplayName($0), identifier: $0.identifier, language: $0.language, quality: $0.quality) }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }
    
    /// 构建声音显示名称，避免质量标签重复（如已含 "Premium" 不再追加）
    /// - Parameter voice: AVSpeechSynthesisVoice 对象
    /// - Returns: 显示用字符串（如 "Tingting (Premium)"）
    private func voiceDisplayName(_ voice: AVSpeechSynthesisVoice) -> String {
        let label = qualityLabel(voice.quality)
        if voice.name.localizedCaseInsensitiveContains(label) {
            return voice.name
        }
        return "\(voice.name) (\(label))"
    }

    /// 将声音质量枚举转换为显示标签字符串
    private func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Default"
        }
    }
    
    // ── TTS 串行管道 ──

    /// TTS 句子队列的 AsyncStream continuation，用于向队列推送新句子
    private var ttsContinuation: AsyncStream<String>.Continuation?

    /// TTS 管道处理 Task，串行消费 AsyncStream 中的句子并逐句播放
    private var ttsPipelineTask: Task<Void, Never>?

    /// 当前响应是否已发送过至少一个 TTS 句子（用于判断 chatFinal 时是否需要再次调用 TTS）
    private var hasSentTTS = false

    /// AVSpeechSynthesizer 实例（复用以避免音频管道频繁重建）
    private var systemSynth: AVSpeechSynthesizer?

    /// AVSpeechSynthesizer Delegate 持有引用（防止被 ARC 释放）
    private var systemSynthDelegate: SystemSpeechDelegate?
    
    // ── 响应去重状态 ──

    /// 当前响应中已处理句子的哈希集合，防止同一句子被说两遍
    private var currentResponseSentenceHashes: Set<Int> = []

    /// 当前响应的 chatFinal 是否已处理（防止重复处理 final）
    private var processingFinalDone = false

    /// 是否正在接收流式响应（首个 delta 到 final 之间为 true）
    private var isReceivingResponse = false
    
    // ── 语音识别（WhisperKit） ──

    /// WhisperKit 语音转文字引擎（主录音用，比唤醒词检测器用更大的模型）
    private var whisperKit: WhisperKit?

    /// 主 WhisperKit 模型是否已就绪
    private var whisperReady = false

    /// 录音用 AVAudioEngine（独立于唤醒词检测器的 audioEngine）
    private var audioEngine = AVAudioEngine()

    /// 录音期间累积的 Float 音频样本，停止录音后送入 WhisperKit 转写
    private var recordedSamples: [Float] = []

    // ── 唤醒词检测器 ──

    /// 唤醒词检测器实例，在 idle 状态下后台监听
    let wakeWordDetector = WakeWordDetector()

    // ── VAD 自动停止参数 ──

    /// VAD 静音计时起点（持续静音后自动停止录音）
    private var vadSilenceStart: Date?
    private var audioTapCount = 0

    /// VAD 自动停止所需静音时长：3.5 秒持续静音后自动停止录音
    private let vadAutoStopSilenceDuration: TimeInterval = 3.5

    /// VAD 能量阈值：RMS 低于此值视为静音
    private let vadAutoStopEnergyThreshold: Float = 0.01

    /// 当前录音是否由唤醒词触发（影响是否启用 VAD 自动停止）
    private var isVoiceWakeTriggered = false

    /// 录音过程中检测到的峰值 RMS（用于判断是否真的有人说话）
    private var peakRmsDuringRecording: Float = 0.0

    /// 最低有效语音 RMS 阈值：峰值低于此值视为背景噪音，丢弃录音
    private let minSpeechRms: Float = 0.008
    
    // ── 网络层 ──

    /// WebSocket 连接实例（actor 类型，自带线程隔离）
    private let connection: WebSocketConnection
    
    /// 从 ~/.openclaw/ 读取 OpenClaw 配置和设备身份信息
    /// 返回 (gatewayToken, deviceToken, deviceId, publicKey, privateKey, elevenLabsApiKey)
    private static func loadOpenClawConfig() -> (gatewayToken: String, deviceToken: String, deviceId: String, publicKey: String, privateKey: String, elevenLabsApiKey: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        
        // 从 ~/.openclaw/openclaw.json 读取 Gateway Token 和 ElevenLabs API Key
        var gatewayToken = ""
        var elevenLabsApiKey = ""
        let configPath = "\(home)/.openclaw/openclaw.json"
        if let data = FileManager.default.contents(atPath: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let gateway = json["gateway"] as? [String: Any],
               let auth = gateway["auth"] as? [String: Any],
               let token = auth["token"] as? String {
                gatewayToken = token
            }
            if let tools = json["tools"] as? [String: Any],
               let tts = tools["tts"] as? [String: Any],
               let key = tts["elevenLabsApiKey"] as? String {
                elevenLabsApiKey = key
            }
        }

        // 从 ~/.openclaw/identity/device.json 读取设备 ID 和密钥对
        var deviceId = ""
        var publicKey = ""
        var privateKey = ""
        let devicePath = "\(home)/.openclaw/identity/device.json"
        if let data = FileManager.default.contents(atPath: devicePath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            deviceId = json["deviceId"] as? String ?? ""
            publicKey = json["publicKeyPem"] as? String ?? ""
            privateKey = json["privateKeyPem"] as? String ?? ""
        }

        // 从 ~/.openclaw/identity/device-auth.json 读取设备 Token
        var deviceToken = ""
        let authPath = "\(home)/.openclaw/identity/device-auth.json"
        if let data = FileManager.default.contents(atPath: authPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tokens = json["tokens"] as? [String: Any],
           let operator_ = tokens["operator"] as? [String: Any],
           let token = operator_["token"] as? String {
            deviceToken = token
        }

        return (gatewayToken, deviceToken, deviceId, publicKey, privateKey, elevenLabsApiKey)
    }
    
    /// 初始化 ChatManager：加载配置、创建 WebSocket 连接、启动 WhisperKit 和唤醒词检测器
    init() {
        let loaded = ChatManager.loadOpenClawConfig()
        
        // 优先使用用户在设置中保存的配置，回退到配置文件中的值
        let savedGatewayURL = UserDefaults.standard.string(forKey: "gatewayURL") ?? "ws://127.0.0.1:18789"
        let savedToken = UserDefaults.standard.string(forKey: "gatewayToken")
        let effectiveToken = (savedToken?.isEmpty == false) ? savedToken! : loaded.gatewayToken
        let savedSession = UserDefaults.standard.string(forKey: "sessionKey") ?? "main"
        
        debugLog("[CM] Loaded config: gateway=\(savedGatewayURL), token=\(effectiveToken.prefix(8))..., session=\(savedSession)")
        
        let config = WebSocketConnection.Config(
            gatewayURL: savedGatewayURL,
            gatewayToken: effectiveToken,
            deviceToken: loaded.deviceToken,
            sessionKey: savedSession,
            protocolVersion: 3,
            elevenLabsApiKey: loaded.elevenLabsApiKey,
            elevenLabsVoiceId: "21m00Tcm4TlvDq8ikWAM",
            deviceId: loaded.deviceId,
            devicePublicKeyPem: loaded.publicKey,
            devicePrivateKeyPem: loaded.privateKey
        )
        connection = WebSocketConnection(config: config)
        
        // 注册为当前最新实例，旧实例将不再播放 TTS
        ChatManager.latestInstanceId = instanceId
        debugLog("[CM] Init instance \(instanceId.uuidString.prefix(8)), now active")
        
        // 显示连接中占位消息
        messages.append(ChatMessage(content: "连接中...", isUser: false))
        
        // 在后台加载 WhisperKit 模型（不阻塞 UI）
        Task {
            await setupWhisperKit()
        }

        // 在后台建立 WebSocket 连接
        Task {
            await startConnection()
        }

        // 将模型路径同步给唤醒词检测器
        wakeWordDetector.modelBasePath = modelBasePath
        
        // 设置唤醒词检测器回调
        wakeWordDetector.onModelLoaded = { [weak self] in
            Task { @MainActor in
                self?.isWakeModelLoaded = true
            }
        }
        wakeWordDetector.onWakeWordDetected = { [weak self] in
            Task { @MainActor in
                self?.handleWakeWordDetected()
            }
        }
        // 加载唤醒词模型，完成后根据开关决定是否立即启动
        Task {
            await wakeWordDetector.setup()
            if voiceWakeEnabled {
                wakeWordDetector.isPaused = false
                wakeWordDetector.startDetecting()
                debugLog("[CM] Wake word detector started (voiceWakeEnabled=true)")
            }
        }
    }

    // MARK: - Wake Word

    /// 处理唤醒词触发事件
    /// 播放提示音（Glass.aiff），延迟 500ms 后开始正式录音（跳过唤醒词尾音）
    private func handleWakeWordDetected() {
        guard state == .idle else { return }
        debugLog("[CM] Wake word detected! Playing alert sound...")
        // 播放系统提示音 Glass.aiff 作为唤醒确认音
        if let sound = NSSound(contentsOfFile: "/System/Library/Sounds/Glass.aiff", byReference: true) {
            sound.play()
            debugLog("[CM] Glass sound played")
        } else {
            debugLog("[CM] ⚠️ Failed to load Glass.aiff, trying fallback")
            NSSound.beep()
        }
        // 标记为唤醒词触发的录音（影响 VAD 自动停止逻辑）
        isVoiceWakeTriggered = true
        // 延迟 500ms 后开始录音，避免麦克风还在接收唤醒词尾音
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard self.state == .idle || self.state == .listening else { return }
            self.startListening()
        }
    }

    /// 处理状态变化：管理唤醒词检测器的暂停/恢复
    /// 进入非 idle 状态时暂停检测，回到 idle 时恢复检测（避免录音/TTS 时干扰）
    private func handleStateChange(from oldState: ChatState, to newState: ChatState) {
        guard voiceWakeEnabled else { return }
        if newState == .idle && oldState != .idle {
            // 回到空闲状态 → 恢复唤醒词检测
            wakeWordDetector.resume()
        } else if newState != .idle && oldState == .idle {
            // 离开空闲状态 → 暂停唤醒词检测
            wakeWordDetector.pause()
        }
    }
    
    // MARK: - Connection
    
    /// 启动 WebSocket 连接，设置事件回调并连接到 Gateway
    private func startConnection() async {
        await connection.setOnEvent { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleConnectionEvent(event)
            }
        }
        await connection.connect()
    }
    
    /// 处理来自 WebSocketConnection 的连接事件
    /// - Parameter event: 连接事件（connected/disconnected/chatSentence/chatFinal 等）
    private func handleConnectionEvent(_ event: ConnectionEvent) {
        switch event {
        case .connected:
            let wasConnected = isConnected
            isConnected = true
            // 移除"连接中..."占位消息
            if let idx = messages.firstIndex(where: { $0.content == "连接中..." }) {
                messages.remove(at: idx)
            }
            if !wasConnected {
                // 首次连接显示欢迎语，重连则显示重连通知
                if messages.isEmpty || messages.allSatisfy({ $0.content.hasPrefix("⚠️") }) {
                    messages.append(ChatMessage(
                        content: "嘿！我是龙虾娘波波～按住麦克风跟我说话，或者直接打字都行！🦞",
                        isUser: false
                    ))
                } else {
                    messages.append(ChatMessage(content: "🔄 已重新连接", isUser: false))
                }
            }
            
        case .disconnected:
            isConnected = false
            
        case .connectionFailed:
            isConnected = false
            
        case .chatSentence(let sentence):
            // 首个 delta 到达，标记响应开始并清空去重状态
            if !isReceivingResponse {
                isReceivingResponse = true
                currentResponseSentenceHashes.removeAll()
                processingFinalDone = false
                debugLog("[CM] New response detected, reset de-dup state")
            }
            // 去重：同一响应内相同句子只播放一次（防止 delta/final 重复发句）
            let hash = sentence.hashValue
            guard currentResponseSentenceHashes.insert(hash).inserted else {
                debugLog("[CM] chatSentence SKIPPED (duplicate): '\(sentence.prefix(50))'")
                return
            }
            debugLog("[CM] chatSentence: '\(sentence.prefix(50))' (hasSentTTS=\(hasSentTTS))")
            state = .speaking
            hasSentTTS = true
            // 将句子推送到 TTS 管道
            enqueueTTS(sentence)
            
        case .chatFinal(let text):
            debugLog("[CM] chatFinal: \(text.count) chars, hasSentTTS=\(hasSentTTS), hashes=\(currentResponseSentenceHashes.count)")
            // 防止重复处理 final（流式传输可能触发多次）
            guard !processingFinalDone else {
                debugLog("[CM] chatFinal SKIPPED (duplicate)")
                return
            }
            processingFinalDone = true
            
            // 若没有收到过 delta（极短响应），重置去重状态
            if !isReceivingResponse {
                currentResponseSentenceHashes.removeAll()
            }
            
            if !text.isEmpty && text != "HEARTBEAT_OK" && text != "NO_REPLY" {
                // 将完整响应文字添加到聊天记录
                messages.append(ChatMessage(content: text, isUser: false))
                if !hasSentTTS {
                    // 没有通过 chatSentence 路径发过 TTS → 在 final 时整段播放
                    state = .speaking
                    enqueueTTS(text)
                }
            } else if !hasSentTTS {
                // 空响应或特殊指令 → 直接回到 idle
                state = .idle
            }
            hasSentTTS = false
            isReceivingResponse = false
            // 结束 TTS 管道：finish continuation，管道处理完剩余句子后自动切换到 idle
            let cont = ttsContinuation
            ttsContinuation = nil
            cont?.finish()
            
        case .chatAborted:
            print("[CM] chatAborted — clearing TTS state")
            hasSentTTS = false
            isReceivingResponse = false
            stopTTSPipeline()
            state = .idle
            
        case .chatError(let errorMsg):
            print("[CM] chatError: \(errorMsg)")
            hasSentTTS = false
            isReceivingResponse = false
            stopTTSPipeline()
            showError(errorMsg)
            
        case .agentThinking:
            print("[CM] agentThinking (current state=\(state))")
            // 不覆盖 speaking 状态（TTS 可能还在播放上一条消息）
            if state != .speaking { state = .thinking }
            
        case .agentDone:
            print("[CM] agentDone (current state=\(state))")
            if state == .thinking { state = .idle }
            
        case .messageSent(let runId):
            _ = runId // 保留供未来使用（如追踪消息 run ID）
            
        case .sendFailed(let reason):
            showError(reason)
        }
    }
    
    // MARK: - Send Message
    
    /// 发送纯文字消息的便利方法
    /// - Parameter text: 消息文字
    func sendMessage(_ text: String) {
        sendMessage(text, images: [])
    }
    
    /// 发送消息（支持文字和图片附件）
    /// 图片附件拆分为多条消息发送，避免超过 Gateway 512KB 载荷限制
    /// - Parameters:
    ///   - text: 消息文字（可为空，仅发图片时为描述语）
    ///   - images: 图片附件数组（base64 编码后随消息发送）
    func sendMessage(_ text: String, images: [ImageAttachment]) {
        guard isConnected else {
            showError("未连接到服务器")
            return
        }
        
        let displayText = text.isEmpty ? "[图片]" : text
        messages.append(ChatMessage(content: displayText, isUser: true, images: images))
        state = .thinking
        
        debugLog("[CM] 📤 发送消息: '\(text.prefix(50))' (图片: \(images.count))")
        
        Task {
            if !images.isEmpty {
                // 每张图片作为独立消息发送，防止单条超过 Gateway 的 512KB 限制
                for (i, img) in images.enumerated() {
                    let msg: String
                    if i == 0 {
                        // 第一条消息附带用户文字（或自动生成描述）
                        msg = text.isEmpty ? "请看这\(images.count > 1 ? "\(images.count)张" : "张")图片" : text
                    } else {
                        // 后续图片标注序号
                        msg = "(续) 第\(i + 1)张图片"
                    }
                    let attachment = [["type": "image", "mimeType": img.mimeType, "fileName": img.fileName, "content": img.data.base64EncodedString()]]
                    debugLog("[CM] Sending image \(i + 1)/\(images.count), fileName=\(img.fileName)")
                    await connection.sendChatWithAttachments(msg, attachments: attachment)
                }
                debugLog("[CM] All \(images.count) image(s) sent")
            } else {
                // 纯文字消息
                await connection.sendChat(text)
            }
        }
    }
    
    // MARK: - TTS Pipeline (serial: fetch → play → next)
    
    /// 将一个句子推送到 TTS 串行管道
    /// 若管道尚未启动则自动创建；已有管道时直接追加到队列
    /// - Parameter sentence: 待播放的文字句子
    private func enqueueTTS(_ sentence: String) {
        // 仅允许最新实例播放 TTS，防止旧实例残留发声
        guard ChatManager.latestInstanceId == instanceId else {
            debugLog("[TTS] enqueueTTS BLOCKED (stale instance \(instanceId.uuidString.prefix(8)))")
            return
        }
        debugLog("[TTS] enqueueTTS: '\(sentence.prefix(40))'")
        
        // 第一个句子到来时创建管道
        if ttsContinuation == nil {
            startTTSPipeline()
        }
        
        // 将句子推送到 AsyncStream 队列
        ttsContinuation?.yield(sentence)
    }
    
    /// 创建 AsyncStream 和处理 Task，串行消费每个句子
    /// 新管道创建时取消旧管道（防止死锁），等待旧管道简短清理后再开始
    private func startTTSPipeline() {
        let stream = AsyncStream<String> { continuation in
            self.ttsContinuation = continuation
        }
        
        // 取消旧管道而非等待（防止旧管道阻塞新管道启动）
        ttsPipelineTask?.cancel()
        let previousTask = ttsPipelineTask
        
        ttsPipelineTask = Task { [weak self] in
            // 给旧管道 200ms 时间完成清理
            if previousTask != nil {
                try? await Task.sleep(for: .milliseconds(200))
            }
            
            // 串行处理队列中的每个句子
            for await sentence in stream {
                guard let self else { break }
                await self.speakWithSystem(sentence)
            }
            
            // 管道队列耗尽 → 切换回 idle 状态
            guard let self else { return }
            debugLog("[TTS] Pipeline finished")
            self.ttsContinuation = nil
            self.ttsPipelineTask = nil
            if self.state == .speaking {
                self.state = .idle
            }
        }
    }
    
    /// 使用 AVSpeechSynthesizer 朗读文字，挂起直到播放完成
    /// 自动过滤 emoji，根据文字语言选择对应的声音
    /// - Parameter text: 待朗读的文字
    private func speakWithSystem(_ text: String) async {
        // 过滤 emoji（保留 ASCII 十六进制数字，如颜色码）
        let cleanText = text.unicodeScalars.filter { scalar in
            !scalar.properties.isEmoji || scalar.properties.isASCIIHexDigit
        }.map(String.init).joined()
        
        // 跳过过滤后为空的文字（如纯 emoji 句子）
        guard !cleanText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            debugLog("[TTS] Skipping empty/emoji-only text: '\(text.prefix(20))'")
            return
        }
        
        let utterance = AVSpeechUtterance(string: cleanText)
        // 根据文字语言选择声音：含中文字符用中文声音，否则用英文声音
        // 优先使用用户选择的高质量声音，逐级降级
        let voice: AVSpeechSynthesisVoice?
        if text.containsChinese {
            voice = AVSpeechSynthesisVoice(identifier: zhVoiceId)
                ?? AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.zh-CN.Tingting")
                ?? AVSpeechSynthesisVoice(language: "zh-CN")
        } else {
            voice = AVSpeechSynthesisVoice(identifier: enVoiceId)
                ?? AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.en-US.Samantha")
                ?? AVSpeechSynthesisVoice(language: "en-US")
        }
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        
        debugLog("[TTS] System speaking (\(voice?.language ?? "?"): \(voice?.name ?? "?")): '\(text.prefix(40))'")
        
        // 使用 CheckedContinuation 将 delegate 回调桥接为 async/await
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // 懒加载 synthesizer，复用实例避免音频管道反复初始化
            if self.systemSynth == nil {
                self.systemSynth = AVSpeechSynthesizer()
            }
            let synth = self.systemSynth!
            let delegate = SystemSpeechDelegate {
                debugLog("[TTS] System speech finished")
                continuation.resume()
            }
            self.systemSynthDelegate = delegate  // 强引用 delegate，防止 ARC 释放
            synth.delegate = delegate
            synth.speak(utterance)
        }
    }
    
    /// 立即停止 TTS 管道并释放相关资源
    /// 在收到 chatAborted / chatError 时调用
    private func stopTTSPipeline() {
        ttsContinuation?.finish()
        ttsContinuation = nil
        ttsPipelineTask?.cancel()
        ttsPipelineTask = nil
        systemSynth?.stopSpeaking(at: .immediate)
        systemSynth = nil
        systemSynthDelegate = nil
    }
    
    // MARK: - WhisperKit Setup
    
    /// 异步加载 WhisperKit 语音识别模型
    /// 按 large-v3 → small → base → tiny 优先级降级，优先使用本地缓存模型
    private func setupWhisperKit() async {
        debugLog("[Whisper] Loading WhisperKit model...")
        
        let localModelsBase = URL(fileURLWithPath: modelBasePath)
        
        // 从最高精度模型开始，找到第一个可用的即停止
        let modelsToTry = ["large-v3", "small", "base", "tiny"]
        
        for modelName in modelsToTry {
            let modelFolder = localModelsBase.appendingPathComponent("openai_whisper-\(modelName)")
            let useLocal = FileManager.default.fileExists(atPath: modelFolder.path)
            
            do {
                debugLog("[Whisper] Trying model: \(modelName) (local=\(useLocal))...")
                let config: WhisperKitConfig
                if useLocal {
                    // 本地模型开启 verbose 和 debug 级别日志，便于调试
                    config = WhisperKitConfig(modelFolder: modelFolder.path, verbose: true, logLevel: .debug)
                } else {
                    config = WhisperKitConfig(model: modelName)
                }
                whisperKit = try await WhisperKit(config)
                whisperReady = true
                debugLog("[Whisper] ✅ Model '\(modelName)' loaded successfully!")
                await MainActor.run { self.isMainModelLoaded = true }
                
                // 加载成功后在聊天记录中显示提示
                await MainActor.run {
                    messages.append(ChatMessage(content: "🎤 语音模型 (\(modelName)) 已加载", isUser: false))
                }
                return
            } catch {
                debugLog("[Whisper] ❌ Model '\(modelName)' failed: \(error.localizedDescription)")
            }
        }
        
        // 所有模型都失败
        debugLog("[Whisper] All models failed to load!")
        await MainActor.run {
            messages.append(ChatMessage(content: "⚠️ 语音模型加载失败，请检查网络连接", isUser: false))
        }
    }
    
    // MARK: - Speech Recognition (WhisperKit)
    
    /// 开始录音
    /// 检查麦克风权限 → 停止 TTS → 启动 AVAudioEngine 录音
    /// 若由唤醒词触发，还会启用 VAD 自动停止逻辑
    func startListening() {
        let micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
        debugLog("[Speech] Mic auth=\(micAuth.rawValue)")
        
        // 权限未确定时先请求，获得结果后重新调用 startListening
        if micAuth == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                debugLog("[Speech] Mic permission result: \(granted)")
                Task { @MainActor in
                    self.startListening()
                }
            }
            return
        }
        
        // WhisperKit 未就绪则提示用户等待
        guard whisperReady else {
            debugLog("[Speech] WhisperKit not ready yet")
            messages.append(ChatMessage(content: "⚠️ 语音模型加载中，请稍等...", isUser: false))
            isVoiceWakeTriggered = false
            state = .idle
            return
        }
        
        // 停止正在播放的 TTS，避免录音期间自己的声音被录入
        systemSynth?.stopSpeaking(at: .immediate)
        
        // 确保之前的 audioEngine 已停止
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        
        // 初始化录音状态
        state = .listening
        currentTranscription = ""
        recordedSamples.removeAll()
        vadSilenceStart = nil
        recordingStartTime = Date()
        peakRmsDuringRecording = 0.0
        
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        let sampleRate = recordingFormat.sampleRate
        debugLog("[Speech] Starting recording, sampleRate=\(sampleRate), channels=\(recordingFormat.channelCount)")
        
        audioTapCount = 0
        // 安装音频 tap：接收麦克风数据，累积样本并计算 RMS
        // 注意：tap 回调在音频渲染线程执行，必须先提取样本和计算 RMS，
        // 再通过 Task { @MainActor } 安全地访问 self 的属性
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            // 在音频线程提取样本（buffer 仅在回调期间有效）
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))

            // 在音频线程计算 RMS 能量（纯计算，无需 MainActor）
            var rms: Float = 0
            for i in 0..<frameLength {
                rms += channelData[i] * channelData[i]
            }
            rms = sqrtf(rms / Float(frameLength))

            // 所有 self 属性访问必须在 MainActor 上执行
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recordedSamples.append(contentsOf: samples)

                self.audioTapCount += 1
                // 更新峰值 RMS（用于后续判断是否真的有人说话）
                if rms > self.peakRmsDuringRecording {
                    self.peakRmsDuringRecording = rms
                }

                // 前三帧和每 100 帧打印一次调试日志
                if self.audioTapCount <= 3 || self.audioTapCount % 100 == 0 {
                    debugLog("[Speech] Audio tap #\(self.audioTapCount): frames=\(frameLength), totalSamples=\(self.recordedSamples.count), rms=\(String(format: "%.6f", rms))")
                }

                // 唤醒词触发的录音才启用 VAD 自动停止
                if self.isVoiceWakeTriggered {
                    self.checkVADAutoStop(rms: rms)
                }
            }
        }
        
        audioEngine.prepare()
        do {
            try audioEngine.start()
            debugLog("[Speech] Audio engine started, isRunning=\(audioEngine.isRunning)")
        } catch {
            debugLog("[Speech] Audio engine failed to start: \(error)")
            state = .error
        }
    }
    
    /// 录音开始时间，用于 VAD 最长录音时间限制
    private var recordingStartTime: Date?

    /// 最长录音时间：超过 30 秒强制停止，防止无限录音
    private let maxRecordingDuration: TimeInterval = 30.0
    
    /// VAD 自动停止检测（仅在唤醒词触发的录音中调用）
    /// 检测两种停止条件：
    ///   1. 录音时长超过 maxRecordingDuration
    ///   2. 持续静音时长超过 vadAutoStopSilenceDuration
    /// - Parameter rms: 当前音频帧的 RMS 能量值
    private func checkVADAutoStop(rms: Float) {
        guard state == .listening, isVoiceWakeTriggered else { return }

        // 超时保护：强制停止
        if let start = recordingStartTime, Date().timeIntervalSince(start) >= maxRecordingDuration {
            debugLog("[Speech] VAD auto-stop: max recording duration reached (\(maxRecordingDuration)s)")
            stopListeningAndSend()
            return
        }

        if rms < vadAutoStopEnergyThreshold {
            // 当前帧为静音 → 开始/继续计时
            if vadSilenceStart == nil {
                vadSilenceStart = Date()
            } else if Date().timeIntervalSince(vadSilenceStart!) >= vadAutoStopSilenceDuration {
                // 静音持续超过阈值 → 自动停止
                debugLog("[Speech] VAD auto-stop triggered after \(vadAutoStopSilenceDuration)s silence")
                stopListeningAndSend()
            }
        } else {
            // 检测到语音 → 重置静音计时器
            vadSilenceStart = nil
        }
    }

    /// 停止录音并自动发送转写结果（VAD 自动停止路径使用）
    /// 若峰值 RMS 过低（背景噪音），则丢弃录音不发送
    private func stopListeningAndSend() {
        guard state == .listening else { return }
        let wasWakeTriggered = isVoiceWakeTriggered
        let peakRms = peakRmsDuringRecording
        isVoiceWakeTriggered = false
        
        // 峰值 RMS 过低 → 判定为背景噪音，丢弃本次录音
        if peakRms < minSpeechRms {
            debugLog("[Speech] 🚫 丢弃录音 — 峰值 rms \(String(format: "%.4f", peakRms)) < \(minSpeechRms)，判定为背景噪音")
            recordedSamples.removeAll()
            stopListening()
            state = .idle
            return
        }
        
        stopListening()

        if wasWakeTriggered {
            Task { @MainActor in
                // 轮询等待 WhisperKit 转写完成（最多等 10 秒）
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if !currentTranscription.isEmpty { break }
                }
                if !currentTranscription.isEmpty {
                    let text = currentTranscription
                    currentTranscription = ""
                    // 播放发送提示音
                    if let sound = NSSound(contentsOfFile: "/System/Library/Sounds/Submarine.aiff", byReference: true) {
                        sound.play()
                    }
                    sendMessage(text)
                }
            }
        }
    }

    /// 停止录音，提取样本并通过 WhisperKit 进行语音转文字
    /// 转写结果写入 currentTranscription，InputAreaView 负责读取并填充输入框
    func stopListening() {
        guard state == .listening else { return }
        
        debugLog("[Speech] Stopping recording, totalSamples=\(recordedSamples.count)")
        
        // 停止 audioEngine 并移除 tap
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        
        state = .idle
        
        // 取出累积的样本，清空缓冲区
        let samples = recordedSamples
        recordedSamples.removeAll()
        
        guard !samples.isEmpty else {
            debugLog("[Speech] No audio samples recorded")
            return
        }
        
        // WhisperKit 要求 16kHz 采样率，对设备实际采样率进行线性插值重采样
        let inputSampleRate = audioEngine.inputNode.outputFormat(forBus: 0).sampleRate
        let targetSampleRate: Double = 16000.0
        let resampledSamples: [Float]
        
        if abs(inputSampleRate - targetSampleRate) > 1.0 {
            // 线性插值重采样
            let ratio = targetSampleRate / inputSampleRate
            let outputLength = Int(Double(samples.count) * ratio)
            var resampled = [Float](repeating: 0, count: outputLength)
            for i in 0..<outputLength {
                let srcIdx = Double(i) / ratio
                let idx = Int(srcIdx)
                let frac = Float(srcIdx - Double(idx))
                if idx + 1 < samples.count {
                    resampled[i] = samples[idx] * (1 - frac) + samples[idx + 1] * frac
                } else if idx < samples.count {
                    resampled[i] = samples[idx]
                }
            }
            resampledSamples = resampled
            debugLog("[Speech] Resampled \(samples.count) → \(outputLength) samples (\(inputSampleRate)Hz → \(targetSampleRate)Hz)")
        } else {
            // 已是 16kHz，无需重采样
            resampledSamples = samples
        }
        
        let durationSec = Double(resampledSamples.count) / targetSampleRate
        debugLog("[Speech] Transcribing \(String(format: "%.1f", durationSec))s of audio with WhisperKit...")
        
        Task { @MainActor in
            do {
                let options = DecodingOptions(
                    task: .transcribe,
                    language: "zh",                // 指定中文，提高识别准确率
                    temperature: 0.0,              // 贪心解码
                    sampleLength: 224,
                    chunkingStrategy: .vad         // 使用 VAD 分块策略处理较长音频
                )
                let results = try await whisperKit?.transcribe(audioArray: resampledSamples, decodeOptions: options)
                var text = results?.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                
                // 清理 Whisper 幻听尾巴（如 "阿姨:阿姨,你吃吧" 等假字幕）
                text = Self.stripHallucinationTail(text)
                
                debugLog("[Speech] ✅ 语音转文字结果: '\(text.prefix(100))'")
                
                if !text.isEmpty {
                    currentTranscription = text
                } else {
                    debugLog("[Speech] WhisperKit returned empty result")
                }
            } catch {
                debugLog("[Speech] WhisperKit transcription error: \(error)")
            }
        }
    }
    
    // MARK: - Hallucination Filter
    
    /// 清理 Whisper 在真实语音末尾附加的幻听内容
    /// Whisper 常见问题：在真实内容后面追加假字幕、假对话、感谢语等
    /// 处理策略：
    ///   1. 检测并去除结尾处已知幻听短语（含/不含分隔符）
    ///   2. 检测分隔符后的幻听模式（如 "阿姨:阿姨你吃吧"）
    ///   3. 若整个文本是幻听则返回空字符串
    /// - Parameter text: 原始转写文本
    /// - Returns: 清理后的文本
    static func stripHallucinationTail(_ text: String) -> String {
        var result = text
        
        // 已知幻听尾部短语列表
        let tailPhrases = [
            "谢谢大家", "谢谢观看", "感谢观看", "感谢收看", "感谢收听",
            "谢谢你的观看", "谢谢你的收看",
            "请不吝点赞", "订阅转发", "点赞订阅",
            "阿姨你吃吧", "阿姨吃吧",
            "please subscribe", "thank you for watching", "like and subscribe",
            "thanks for watching"
        ]
        
        // 从结尾去除已知幻听短语，并清理残留分隔符
        let lower = result.lowercased()
        for phrase in tailPhrases {
            let p = phrase.lowercased()
            if lower.hasSuffix(p) && lower.count > p.count {
                result = String(result.dropLast(phrase.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                // 清理结尾残留的分隔符
                while result.hasSuffix(":") || result.hasSuffix("：") || result.hasSuffix("。") || result.hasSuffix("|") || result.hasSuffix(",") || result.hasSuffix("，") {
                    result = String(result.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                break
            }
        }
        
        // 检测分隔符后的幻听内容（如 "你好：阿姨你吃吧" → 保留"你好"）
        let separators: [Character] = [":", "：", "|", "。"]
        for sep in separators {
            if let sepIdx = result.lastIndex(of: sep) {
                let tail = String(result[result.index(after: sepIdx)...]).trimmingCharacters(in: .whitespaces).lowercased()
                let sepPatterns = ["阿姨", "字幕", "订阅", "点赞", "转发", "打赏", "频道", "栏目", "明镜"]
                for pattern in sepPatterns {
                    if tail.contains(pattern.lowercased()) {
                        result = String(result[..<sepIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
                        break
                    }
                }
            }
        }
        
        // 整体幻听过滤：若整段文字就是一个幻听词，返回空字符串
        let finalLower = result.lowercased()
        let fullHallucinations = ["字幕", "订阅", "点赞", "转发", "谢谢", "谢谢大家", "(笑)", "(拍)", "♪"]
        for h in fullHallucinations {
            if finalLower == h.lowercased() { return "" }
        }
        
        return result
    }
    
    // MARK: - Error Handling
    
    /// 显示错误消息，2 秒后自动恢复为 idle 状态
    /// - Parameter message: 错误描述文字（将在消息中加 ⚠️ 前缀）
    private func showError(_ message: String) {
        state = .error
        messages.append(ChatMessage(content: "⚠️ \(message)", isUser: false))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.state = .idle
        }
    }
}

// MARK: - Connection Events

/// WebSocket 连接事件枚举：描述连接层的所有可能事件
enum ConnectionEvent {
    /// 连接成功建立
    case connected
    /// 连接断开（含断开原因）
    case disconnected(String)
    /// 连接失败（含失败原因）
    case connectionFailed(String)
    /// 流式响应中的完整句子（可立即送 TTS 播放）
    case chatSentence(String)
    /// 流式响应结束，包含完整的最终文本
    case chatFinal(String)
    /// 响应被中断（用户取消或服务端中断）
    case chatAborted
    /// 聊天发生错误
    case chatError(String)
    /// Agent 正在处理中（显示 thinking 状态）
    case agentThinking
    /// Agent 处理完成
    case agentDone
    /// 消息发送成功（附带 run ID，可用于追踪）
    case messageSent(String?)
    /// 消息发送失败
    case sendFailed(String)
}

// MARK: - WebSocket Connection (runs off main actor)

/// WebSocket 连接 actor：处理所有网络通信，与主线程隔离
/// 负责：协议握手、消息序列化、流式响应分句、自动断线重连
actor WebSocketConnection {
    /// 连接配置（Sendable，可跨 actor 传递）
    struct Config: Sendable {
        /// WebSocket 服务器地址（ws:// 或 wss://）
        let gatewayURL: String
        /// Gateway 认证 Token
        let gatewayToken: String
        /// 设备 Token（用于设备身份验证）
        let deviceToken: String
        /// 目标会话 Key（路由到 OpenClaw 中的特定 session）
        let sessionKey: String
        /// 协议版本号（当前为 3）
        let protocolVersion: Int
        /// ElevenLabs API Key（可选，暂未使用）
        let elevenLabsApiKey: String
        /// ElevenLabs 声音 ID（可选）
        let elevenLabsVoiceId: String
        /// 设备唯一 ID
        let deviceId: String
        /// 设备 Ed25519 公钥（PEM 格式，用于挑战验证）
        let devicePublicKeyPem: String
        /// 设备 Ed25519 私钥（PEM 格式，用于签名挑战）
        let devicePrivateKeyPem: String
    }
    
    /// 连接配置
    let config: Config

    /// 事件回调函数（发送 ConnectionEvent 到 ChatManager）
    private var _onEvent: (@Sendable (ConnectionEvent) -> Void)?
    
    /// 设置事件回调
    func setOnEvent(_ handler: @escaping @Sendable (ConnectionEvent) -> Void) {
        _onEvent = handler
    }
    
    /// 触发事件，调用回调函数
    private func emit(_ event: ConnectionEvent) {
        _onEvent?(event)
    }
    
    /// 待处理请求的类型（用于在收到响应时知道对应哪种请求）
    private enum PendingRequestType {
        case connect  // connect 握手请求
        case chat     // chat.send 消息请求
    }
    
    /// 当前 WebSocket 任务
    private var webSocket: URLSessionWebSocketTask?

    /// 请求 ID 计数器（自增，生成 "req-1", "req-2" 等 ID）
    private var requestId = 0

    /// 待处理请求字典：requestId → 请求类型
    private var pendingRequests: [String: PendingRequestType] = [:]

    /// 当前流式响应的累积文本缓冲区
    private var currentResponseBuffer = ""

    /// TTS 分句进度：已处理到 currentResponseBuffer 的哪个字符位置
    private var ttsSentIndex = 0

    /// 当前挑战 nonce（服务端发送，用于签名验证）
    private var challengeNonce: String?
    
    /// 句子结束符集合（中英文标点及换行）
    private static let sentenceEnders: CharacterSet = CharacterSet(charactersIn: "。！？；\n.!?;")
    
    init(config: Config) {
        self.config = config
    }
    
    /// 是否允许断线后重连（stop 时设为 false 阻止重连）
    private var shouldReconnect = true
    /// 当前重连尝试次数（用于指数退避计算）
    private var reconnectAttempt = 0
    
    // MARK: - Connect
    
    /// 启动连接（重置重连状态）
    func connect() async {
        shouldReconnect = true
        reconnectAttempt = 0
        await doConnect()
    }
    
    /// 实际执行连接操作：构建 URL（含 token 参数）、创建 WebSocket、进入接收循环
    private func doConnect() async {
        guard var urlComponents = URLComponents(string: config.gatewayURL) else { return }
        
        // 将认证 token 附加到 URL query string
        if !config.gatewayToken.isEmpty {
            urlComponents.queryItems = [URLQueryItem(name: "token", value: config.gatewayToken)]
        }
        
        guard let url = urlComponents.url else { return }
        
        // 重置连接状态，确保干净的起点
        pendingRequests.removeAll()
        requestId = 0
        currentResponseBuffer = ""
        ttsSentIndex = 0
        
        let session = URLSession(configuration: .default)
        webSocket = session.webSocketTask(with: url)
        webSocket?.resume()
        
        debugLog("[WS] Connecting to \(config.gatewayURL) (attempt \(reconnectAttempt))")
        await receiveLoop()
    }
    
    // MARK: - Receive Loop
    
    /// WebSocket 接收循环：持续等待并处理服务端消息
    /// 断线时根据 shouldReconnect 决定是否指数退避重连（最大 30 秒间隔）
    private func receiveLoop() async {
        while let ws = webSocket {
            do {
                let message = try await ws.receive()
                reconnectAttempt = 0  // 成功接收消息，重置重连计数
                switch message {
                case .string(let text):
                    handleWSMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleWSMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                webSocket = nil
                emit(.disconnected(error.localizedDescription))
                
                // 指数退避重连：2s, 4s, 6s... 最大 30s
                if shouldReconnect {
                    reconnectAttempt += 1
                    let delay = min(Double(reconnectAttempt) * 2.0, 30.0)
                    debugLog("[WS] Disconnected, reconnecting in \(delay)s (attempt \(reconnectAttempt))")
                    try? await Task.sleep(for: .seconds(delay))
                    if shouldReconnect {
                        await doConnect()
                    }
                }
                break
            }
        }
    }
    
    // MARK: - Send Chat
    
    /// 发送纯文字聊天消息
    /// - Parameter text: 消息文字内容
    func sendChat(_ text: String) {
        let id = nextRequestId()
        let idempotencyKey = UUID().uuidString  // 幂等键，防止重复发送
        
        let params: [String: Any] = [
            "sessionKey": config.sessionKey,
            "message": text,
            "idempotencyKey": idempotencyKey
        ]
        
        let request: [String: Any] = [
            "type": "req",
            "id": id,
            "method": "chat.send",
            "params": params
        ]
        
        pendingRequests[id] = .chat
        sendFrame(request)
    }
    
    /// 发送带图片附件的聊天消息
    /// 附件以 base64 编码嵌入，发送前验证 JSON 序列化结果
    /// - Parameters:
    ///   - text: 消息文字
    ///   - attachments: 附件数组，每项含 type/mimeType/fileName/content(base64)
    func sendChatWithAttachments(_ text: String, attachments: [[String: String]]) {
        let id = nextRequestId()
        let idempotencyKey = UUID().uuidString
        
        // 转换为 [String: Any] 确保 JSON 序列化正确
        let anyAttachments: [[String: Any]] = attachments.map { $0 as [String: Any] }
        
        let params: [String: Any] = [
            "sessionKey": config.sessionKey,
            "message": text,
            "attachments": anyAttachments,
            "idempotencyKey": idempotencyKey
        ]
        
        let request: [String: Any] = [
            "type": "req",
            "id": id,
            "method": "chat.send",
            "params": params
        ]
        
        // 调试：验证序列化是否成功并记录载荷大小
        if let data = try? JSONSerialization.data(withJSONObject: request) {
            let totalSize = data.count
            let contentLen = attachments.first?["content"]?.count ?? 0
            debugLog("[WS] sendChatWithAttachments: total=\(totalSize) bytes, attachments=\(anyAttachments.count), b64ContentLen=\(contentLen)")
            
            // 验证 JSON 中确实包含 attachments 和 content 字段
            if let jsonStr = String(data: data, encoding: .utf8) {
                let hasAttachments = jsonStr.contains("\"attachments\"")
                let hasContent = jsonStr.contains("\"content\"")
                debugLog("[WS] sendChatWithAttachments JSON check: hasAttachments=\(hasAttachments), hasContent=\(hasContent)")
            }
        } else {
            debugLog("[WS] sendChatWithAttachments: JSON serialization FAILED")
        }
        
        pendingRequests[id] = .chat
        sendFrame(request)
    }
    
    // MARK: - Internal
    
    /// 生成下一个请求 ID（格式："req-N"）
    private func nextRequestId() -> String {
        requestId += 1
        return "req-\(requestId)"
    }
    
    /// 发送 connect 握手请求
    /// 携带客户端信息、协议版本、权限范围和认证信息
    private func sendConnect() {
        let id = nextRequestId()
        
        // 客户端元信息（用于 Gateway 识别和日志）
        let clientInfo: [String: Any] = [
            "id": "openclaw-macos",
            "displayName": "Clawgirl",
            "version": "1.0.0",
            "platform": "darwin",
            "mode": "ui",
            "instanceId": String(UUID().uuidString.prefix(8)).lowercased()
        ]
        
        var params: [String: Any] = [
            "minProtocol": config.protocolVersion,
            "maxProtocol": config.protocolVersion,
            "client": clientInfo,
            "role": "operator",
            "scopes": ["operator.admin", "operator.read"],
            "caps": [] as [String],
            "commands": [] as [String],
            "permissions": [:] as [String: Any],
            "locale": Locale.current.identifier,
            "userAgent": "clawdavatar-macos/1.0.0"
        ]
        
        // 认证策略：有设备 token 则双重认证，否则仅用 gateway token
        if !config.deviceToken.isEmpty {
            params["auth"] = ["deviceToken": config.deviceToken, "token": config.gatewayToken]
        } else if !config.gatewayToken.isEmpty {
            params["auth"] = ["token": config.gatewayToken]
        }
        
        // 本地连接使用 gateway token 认证，无需设备签名
        debugLog("[WS] sendConnect: using gateway token auth (no device signature)")
        
        let request: [String: Any] = [
            "type": "req",
            "id": id,
            "method": "connect",
            "params": params
        ]
        
        pendingRequests[id] = .connect
        sendFrame(request)
    }
    
    /// 使用设备 Ed25519 私钥对 Gateway 挑战进行签名
    /// 签名载荷格式（v2）："v2|deviceId|clientId|clientMode|role|scopes|signedAtMs|token|nonce"
    /// - Parameters:
    ///   - nonce: 服务端发送的挑战随机数
    ///   - signedAt: 签名时间戳（毫秒）
    /// - Returns: base64 编码的签名字符串，签名失败返回 nil
    private func signChallenge(nonce: String, signedAt: Int64) -> String? {
        guard let privateKey = parseEd25519PrivateKey(pem: config.devicePrivateKeyPem) else {
            debugLog("[WS] signChallenge: failed to parse private key")
            return nil
        }
        
        // 构建 v2 签名载荷
        let scopes = "operator.admin,operator.read"
        let payload = "v2|\(config.deviceId)|openclaw-macos|ui|operator|\(scopes)|\(signedAt)|\(config.gatewayToken)|\(nonce)"
        
        debugLog("[WS] signChallenge payload: \(payload.prefix(120))...")
        
        guard let payloadData = payload.data(using: .utf8) else { return nil }

        guard let signature = try? privateKey.signature(for: payloadData) else { return nil }
        return signature.base64EncodedString()
    }
    
    /// 解析 PEM 编码的 Ed25519 私钥为 CryptoKit Curve25519 签名密钥
    /// 支持 PKCS#8 包装格式（48 字节 DER）和原始格式（32 字节）
    /// - Parameter pem: PEM 格式私钥字符串
    /// - Returns: CryptoKit 私钥，解析失败返回 nil
    private func parseEd25519PrivateKey(pem: String) -> Curve25519.Signing.PrivateKey? {
        // 去除 PEM 头尾标记和换行，得到 base64 内容
        let stripped = pem
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)
        
        guard let derData = Data(base64Encoded: stripped) else { return nil }
        
        // PKCS#8 包装的 Ed25519 密钥：DER 结构末尾 32 字节为原始密钥
        // DER 结构：SEQUENCE { SEQUENCE { OID(ed25519) }, OCTET STRING { OCTET STRING { key } } }
        if derData.count == 48 {
            let rawKey = derData.suffix(32)
            return try? Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
        } else if derData.count == 32 {
            // 原始 32 字节密钥
            return try? Curve25519.Signing.PrivateKey(rawRepresentation: derData)
        }
        return nil
    }
    
    /// 将字典序列化为 JSON 并通过 WebSocket 发送
    /// - Parameter dict: 要发送的请求字典
    private func sendFrame(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else {
            debugLog("[WS] sendFrame: JSON serialization failed!")
            return
        }
        
        let method = dict["method"] as? String ?? "?"
        debugLog("[WS] sendFrame: method=\(method), size=\(text.count) chars")
        
        let callback = _onEvent
        webSocket?.send(.string(text)) { error in
            if let error = error {
                debugLog("[WS] sendFrame SEND ERROR: \(error.localizedDescription)")
                callback?(.sendFailed(error.localizedDescription))
            } else {
                debugLog("[WS] sendFrame: sent OK (\(method))")
            }
        }
    }
    
    /// 解析收到的 WebSocket 消息（JSON），分发到 event 或 res 处理器
    private func handleWSMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }
        
        switch type {
        case "event":
            handleEvent(json)
        case "res":
            handleResponse(json)
        default:
            break
        }
    }
    
    /// 处理服务端响应（type = "res"）
    /// 根据对应的请求类型触发 connected / messageSent / 错误事件
    private func handleResponse(_ json: [String: Any]) {
        guard let id = json["id"] as? String,
              let requestType = pendingRequests.removeValue(forKey: id) else {
            return
        }
        
        let ok = json["ok"] as? Bool ?? false
        debugLog("[WS] handleResponse: id=\(id), ok=\(ok), type=\(requestType)")
        
        if ok {
            switch requestType {
            case .connect:
                emit(.connected)
            case .chat:
                let runId = (json["payload"] as? [String: Any])?["runId"] as? String
                emit(.messageSent(runId))
            }
        } else {
            let errorDict = json["error"] as? [String: Any]
            let message = errorDict?["message"] as? String ?? "Request failed"
            debugLog("[WS] handleResponse ERROR: \(message)")
            switch requestType {
            case .connect:
                emit(.connectionFailed(message))
            case .chat:
                emit(.sendFailed(message))
            }
        }
    }
    
    /// 处理服务端事件（type = "event"）
    /// 分发到 connect.challenge / chat / agent / tick 各专项处理器
    private func handleEvent(_ json: [String: Any]) {
        guard let event = json["event"] as? String,
              let payload = json["payload"] as? [String: Any] else {
            return
        }
        
        switch event {
        case "connect.challenge":
            // 服务端挑战：保存 nonce 并发送 connect 握手
            challengeNonce = payload["nonce"] as? String
            sendConnect()
        case "chat":
            handleChatEvent(payload)
        case "agent":
            handleAgentEvent(payload)
        case "tick":
            break  // 心跳消息，忽略
        default:
            break
        }
    }
    
    /// 处理聊天事件（state = delta/final/aborted/error）
    /// - delta：累积流式文本到 currentResponseBuffer，并调用 extractSentences 分句发 TTS
    /// - final：发送剩余文本句子，触发 chatFinal 事件
    /// - aborted/error：清空缓冲区，触发对应事件
    private func handleChatEvent(_ payload: [String: Any]) {
        guard let stateStr = payload["state"] as? String else { return }
        
        switch stateStr {
        case "delta":
            // 流式增量更新：提取文本块追加到缓冲区，尝试提取完整句子发 TTS
            if let message = payload["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                var fullText = ""
                for block in content {
                    if block["type"] as? String == "text",
                       let text = block["text"] as? String {
                        fullText += text
                    }
                }
                debugLog("[WS] delta: buffer=\(fullText.count) chars, ttsSentIndex=\(ttsSentIndex)")
                currentResponseBuffer = fullText
                extractSentences()
            }
            
        case "final":
            // 最终响应：发送未处理的剩余文本，触发 chatFinal
            var finalText = ""
            if let message = payload["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content {
                    if block["type"] as? String == "text",
                       let text = block["text"] as? String {
                        finalText += text
                    }
                }
            }
            // 如果 final payload 中没有文本，则用 delta 累积的缓冲区
            if finalText.isEmpty {
                finalText = currentResponseBuffer
            }
            
            // 发送 ttsSentIndex 之后尚未处理的剩余文本
            let remaining = String(finalText.dropFirst(ttsSentIndex)).trimmingCharacters(in: .whitespacesAndNewlines)
            debugLog("[WS] final: total=\(finalText.count) chars, buffer=\(currentResponseBuffer.count) chars, remaining='\(remaining.prefix(80))'")
            if !remaining.isEmpty {
                emit(.chatSentence(remaining))
            }
            
            // 重置缓冲区状态
            currentResponseBuffer = ""
            ttsSentIndex = 0
            emit(.chatFinal(finalText))
            
        case "aborted":
            currentResponseBuffer = ""
            ttsSentIndex = 0
            emit(.chatAborted)
            
        case "error":
            let errorMsg = payload["errorMessage"] as? String ?? "Unknown error"
            currentResponseBuffer = ""
            ttsSentIndex = 0
            emit(.chatError(errorMsg))
            
        default:
            break
        }
    }
    
    /// 从响应缓冲区中提取完整句子并发送给 TTS
    /// 从 ttsSentIndex 开始扫描，遇到句子结束符时提取并更新 ttsSentIndex
    /// 未到结束符的尾部文本保留，等待后续 delta 补充
    private func extractSentences() {
        let chars = Array(currentResponseBuffer)
        guard chars.count > ttsSentIndex else { return }
        
        var lastSplit = ttsSentIndex
        for i in ttsSentIndex..<chars.count {
            let ch = chars[i]
            // 检测中英文句子结束符
            if "。！？；!?;\n".contains(ch) {
                let sentenceChars = chars[lastSplit...i]
                let sentence = String(sentenceChars).trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty {
                    debugLog("[WS] Sentence extracted: '\(sentence.prefix(50))'")
                    emit(.chatSentence(sentence))
                }
                lastSplit = i + 1
            }
        }
        // 更新已处理位置
        ttsSentIndex = lastSplit
    }
    
    /// 处理 Agent 状态事件（thinking/running/done/idle）
    private func handleAgentEvent(_ payload: [String: Any]) {
        guard let status = payload["status"] as? String else { return }
        
        switch status {
        case "thinking", "running":
            emit(.agentThinking)
        case "done", "idle":
            emit(.agentDone)
        default:
            break
        }
    }
}

// MARK: - System Speech Delegate

/// AVSpeechSynthesizer 的 Delegate，用于监听 TTS 播放完成/取消事件
/// 将 Objective-C delegate 回调桥接为 Swift 闭包（配合 CheckedContinuation 实现 async/await）
class SystemSpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    /// TTS 播放结束（完成或取消）时调用的闭包
    var onFinish: (() -> Void)?
    
    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }
    
    /// 句子播放完成回调
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish?()
        onFinish = nil  // 防止重复触发
    }
    
    /// 句子播放被取消回调（如调用 stopSpeaking 时触发）
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        debugLog("[TTS] System speech cancelled")
        onFinish?()
        onFinish = nil
    }
}

// MARK: - String Language Detection

private extension String {
    /// 检测字符串是否包含中文字符（CJK 统一汉字范围）
    /// 用于 TTS 声音选择：含中文则用中文声音，否则用英文声音
    var containsChinese: Bool {
        contains { ch in
            guard let scalar = ch.unicodeScalars.first else { return false }
            // CJK 统一汉字：U+4E00–U+9FFF
            // CJK 扩展 A：U+3400–U+4DBF
            return (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
        }
    }
}

// MARK: - Color Hex Extension

/// Color 扩展：支持 16 进制颜色字符串初始化（3/6/8 位格式）
extension Color {
    /// 从十六进制字符串创建颜色
    /// - Parameter hex: 十六进制颜色码，支持 "RGB"(3位)/"RRGGBB"(6位)/"AARRGGBB"(8位) 格式
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)：每个通道 4 位，扩展为 8 位
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
