import Foundation
import AudioToolbox
import AVFoundation
import Combine
import CoreML
import CryptoKit
import os.log
import SwiftUI
import WhisperKit

/// Debug logger that writes to both console and a file for inspection.
/// Uses a persistent file handle to avoid open/close overhead on every call.
private let ttsLog = Logger(subsystem: "com.clawd.avatar", category: "TTS")
private let debugLogHandle: FileHandle? = {
    let logPath = "/tmp/clawd_tts_debug.log"
    if !FileManager.default.fileExists(atPath: logPath) {
        FileManager.default.createFile(atPath: logPath, contents: nil)
    }
    return FileHandle(forWritingAtPath: logPath)
}()

nonisolated func debugLog(_ msg: String) {
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(ts)] \(msg)\n"
    print(line, terminator: "")
    if let data = line.data(using: .utf8) {
        debugLogHandle?.seekToEndOfFile()
        debugLogHandle?.write(data)
    }
}

// MARK: - Chat State
enum ChatState: Equatable {
    case idle
    case listening
    case thinking
    case speaking
    case error
    
    var primaryColor: Color {
        switch self {
        case .idle: return Color(hex: "5bbce4")      // ocean blue
        case .listening: return Color(hex: "48d1cc")  // medium turquoise
        case .thinking: return Color(hex: "f0c27f")   // warm sand
        case .speaking: return Color(hex: "ff6b6b")   // coral
        case .error: return Color(hex: "e74c3c")
        }
    }
    
    var secondaryColor: Color {
        switch self {
        case .idle: return Color(hex: "2980b9")       // deep ocean
        case .listening: return Color(hex: "20b2aa")   // light sea green
        case .thinking: return Color(hex: "e6a95c")   // deeper sand
        case .speaking: return Color(hex: "e05555")   // deeper coral
        case .error: return Color(hex: "c0392b")
        }
    }
    
    var glowColor: Color { primaryColor }
    var eyeColor: Color { primaryColor }
}

// MARK: - Image Attachment
struct ImageAttachment: Equatable, Identifiable {
    let id = UUID()
    let data: Data
    let fileName: String
    let mimeType: String
}

// MARK: - Chat Message
struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let content: String
    let isUser: Bool
    let timestamp: Date
    let images: [ImageAttachment]
    
    init(content: String, isUser: Bool, images: [ImageAttachment] = []) {
        self.content = content
        self.isUser = isUser
        self.timestamp = Date()
        self.images = images
    }
}

// MARK: - Voice Option
struct VoiceOption: Identifiable, Hashable {
    let id: String
    let name: String
    let identifier: String
    let language: String
    let quality: AVSpeechSynthesisVoiceQuality
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: VoiceOption, rhs: VoiceOption) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Chat Manager
/// UI state is updated on MainActor via @Published.
/// All networking and heavy work runs off the main thread.
@MainActor
class ChatManager: ObservableObject {
    /// Global instance ID counter — only the latest instance speaks TTS.
    /// This prevents duplicate speech from stale instances (e.g. leftover from ExecuteSnippet).
    private static var latestInstanceId: UUID?
    private let instanceId = UUID()
    @Published var state: ChatState = .idle {
        didSet {
            handleStateChange(from: oldValue, to: state)
        }
    }
    @Published var messages: [ChatMessage] = []
    @Published var currentTranscription: String = ""
    @Published var isConnected: Bool = false
    @Published var wakeWordsDisplay: [String] = {
        if let saved = UserDefaults.standard.array(forKey: "wakeWords") as? [String], !saved.isEmpty {
            return saved
        }
        return WakeWordDetector.defaultWakeWords
    }()
    
    func addWakeWord(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !wakeWordsDisplay.contains(trimmed) else { return }
        wakeWordsDisplay.append(trimmed)
        wakeWordDetector.wakeWords = wakeWordsDisplay
    }
    
    func removeWakeWord(_ word: String) {
        wakeWordsDisplay.removeAll { $0 == word }
        wakeWordDetector.wakeWords = wakeWordsDisplay
    }
    
    func resetWakeWords() {
        wakeWordsDisplay = WakeWordDetector.defaultWakeWords
        wakeWordDetector.wakeWords = wakeWordsDisplay
    }
    
    @Published var voiceWakeEnabled: Bool = UserDefaults.standard.bool(forKey: "voiceWakeEnabled") {
        didSet {
            UserDefaults.standard.set(voiceWakeEnabled, forKey: "voiceWakeEnabled")
            if voiceWakeEnabled {
                // Request mic permission then start detecting
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
                wakeWordDetector.stopDetecting()
                wakeWordDetector.isPaused = true
            }
        }
    }
    
    // Voice selection
    @Published var zhVoiceId: String = "com.apple.voice.premium.zh-HK.Wing"
    @Published var enVoiceId: String = "com.apple.voice.premium.en-AU.Matilda"
    @Published var isWakeModelLoaded: Bool = false
    @Published var isMainModelLoaded: Bool = false
    
    // User-configurable settings
    @Published var gatewayURL: String = UserDefaults.standard.string(forKey: "gatewayURL") ?? "ws://127.0.0.1:18789" {
        didSet { UserDefaults.standard.set(gatewayURL, forKey: "gatewayURL") }
    }
    @Published var gatewayToken: String = UserDefaults.standard.string(forKey: "gatewayToken") ?? "" {
        didSet { UserDefaults.standard.set(gatewayToken, forKey: "gatewayToken") }
    }
    @Published var sessionKey: String = UserDefaults.standard.string(forKey: "sessionKey") ?? "main" {
        didSet { UserDefaults.standard.set(sessionKey, forKey: "sessionKey") }
    }
    
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
    
    static var defaultModelPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml")
            .path
    }
    var zhVoiceOptions: [VoiceOption] {
        var seen = Set<String>()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") || $0.language.hasPrefix("yue") }
            .filter { seen.insert($0.identifier).inserted }
            .map { VoiceOption(id: $0.identifier, name: voiceDisplayName($0), identifier: $0.identifier, language: $0.language, quality: $0.quality) }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }
    var enVoiceOptions: [VoiceOption] {
        var seen = Set<String>()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .filter { seen.insert($0.identifier).inserted }
            .map { VoiceOption(id: $0.identifier, name: voiceDisplayName($0), identifier: $0.identifier, language: $0.language, quality: $0.quality) }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }
    
    /// Build display name: avoid "(Premium) (Premium)" when the voice name already contains the quality tag.
    private func voiceDisplayName(_ voice: AVSpeechSynthesisVoice) -> String {
        let label = qualityLabel(voice.quality)
        if voice.name.localizedCaseInsensitiveContains(label) {
            return voice.name
        }
        return "\(voice.name) (\(label))"
    }

    private func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Default"
        }
    }
    
    // TTS sentence queue — sentences are enqueued here, processed serially by ttsPipeline
    private var ttsContinuation: AsyncStream<String>.Continuation?
    private var ttsPipelineTask: Task<Void, Never>?
    private var hasSentTTS = false
    private var systemSynth: AVSpeechSynthesizer?
    private var systemSynthDelegate: SystemSpeechDelegate?
    
    // De-duplication: track the current response's sentence hashes to avoid speaking duplicates
    private var currentResponseSentenceHashes: Set<Int> = []
    private var processingFinalDone = false
    private var isReceivingResponse = false  // true between first delta and final
    
    // Speech recognition (WhisperKit)
    private var whisperKit: WhisperKit?
    private var whisperReady = false
    private var audioEngine = AVAudioEngine()
    private var recordedSamples: [Float] = []  // Accumulated audio samples during recording

    // Wake word detection
    let wakeWordDetector = WakeWordDetector()

    // VAD for auto-stop during voice recording
    private var vadSilenceStart: Date?
    private let vadAutoStopSilenceDuration: TimeInterval = 3.5
    private let vadAutoStopEnergyThreshold: Float = 0.01
    private var isVoiceWakeTriggered = false  // true when recording was started by wake word
    private var peakRmsDuringRecording: Float = 0.0  // Track peak energy to filter background noise
    private let minSpeechRms: Float = 0.008  // Below this = background noise, discard
    
    // Networking layer (runs off main actor)
    private let connection: WebSocketConnection
    
    /// Read OpenClaw config from ~/.openclaw/openclaw.json and ~/.openclaw/identity/
    private static func loadOpenClawConfig() -> (gatewayToken: String, deviceToken: String, deviceId: String, publicKey: String, privateKey: String, elevenLabsApiKey: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        
        // Read gateway token from openclaw.json
        var gatewayToken = ""
        let configPath = "\(home)/.openclaw/openclaw.json"
        if let data = FileManager.default.contents(atPath: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let gateway = json["gateway"] as? [String: Any],
           let auth = gateway["auth"] as? [String: Any],
           let token = auth["token"] as? String {
            gatewayToken = token
        }
        
        // Read device identity from identity/device.json
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
        
        // Read device token from identity/device-auth.json
        var deviceToken = ""
        let authPath = "\(home)/.openclaw/identity/device-auth.json"
        if let data = FileManager.default.contents(atPath: authPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tokens = json["tokens"] as? [String: Any],
           let operator_ = tokens["operator"] as? [String: Any],
           let token = operator_["token"] as? String {
            deviceToken = token
        }
        
        // Read ElevenLabs API key from openclaw.json (if configured)
        var elevenLabsApiKey = ""
        if let data = FileManager.default.contents(atPath: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tools = json["tools"] as? [String: Any],
           let tts = tools["tts"] as? [String: Any],
           let key = tts["elevenLabsApiKey"] as? String {
            elevenLabsApiKey = key
        }
        
        return (gatewayToken, deviceToken, deviceId, publicKey, privateKey, elevenLabsApiKey)
    }
    
    init() {
        let loaded = ChatManager.loadOpenClawConfig()
        
        // Read saved settings, fall back to defaults / config file
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
        
        // Register as the latest (active) instance — older instances will stop speaking
        ChatManager.latestInstanceId = instanceId
        debugLog("[CM] Init instance \(instanceId.uuidString.prefix(8)), now active")
        
        messages.append(ChatMessage(content: "连接中...", isUser: false))
        
        // Load WhisperKit model in background
        Task {
            await setupWhisperKit()
        }

        Task {
            await startConnection()
        }

        // Sync model path to wake word detector
        wakeWordDetector.modelBasePath = modelBasePath
        
        // Setup wake word detector
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

    private func handleWakeWordDetected() {
        guard state == .idle else { return }
        debugLog("[CM] Wake word detected! Playing alert sound...")
        // Play Glass system sound — load from system sounds directory
        if let sound = NSSound(contentsOfFile: "/System/Library/Sounds/Glass.aiff", byReference: true) {
            sound.play()
            debugLog("[CM] Glass sound played")
        } else {
            debugLog("[CM] ⚠️ Failed to load Glass.aiff, trying fallback")
            NSSound.beep()
        }
        // Delay before recording to skip wake word tail audio
        isVoiceWakeTriggered = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard self.state == .idle || self.state == .listening else { return }
            self.startListening()
        }
    }

    private func handleStateChange(from oldState: ChatState, to newState: ChatState) {
        guard voiceWakeEnabled else { return }
        if newState == .idle && oldState != .idle {
            // Back to idle — resume wake word detection
            wakeWordDetector.resume()
        } else if newState != .idle && oldState == .idle {
            // Leaving idle — pause wake word detection
            wakeWordDetector.pause()
        }
    }
    
    // MARK: - Connection
    
    private func startConnection() async {
        await connection.setOnEvent { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleConnectionEvent(event)
            }
        }
        await connection.connect()
    }
    
    private func handleConnectionEvent(_ event: ConnectionEvent) {
        switch event {
        case .connected:
            let wasConnected = isConnected
            isConnected = true
            if let idx = messages.firstIndex(where: { $0.content == "连接中..." }) {
                messages.remove(at: idx)
            }
            if !wasConnected {
                // Show welcome only on first connect; show reconnect notice otherwise
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
            // Reset de-duplication state when a new response starts
            if !isReceivingResponse {
                isReceivingResponse = true
                currentResponseSentenceHashes.removeAll()
                processingFinalDone = false
                debugLog("[CM] New response detected, reset de-dup state")
            }
            // De-duplicate: skip if we've already enqueued this exact sentence in this response
            let hash = sentence.hashValue
            guard currentResponseSentenceHashes.insert(hash).inserted else {
                debugLog("[CM] chatSentence SKIPPED (duplicate): '\(sentence.prefix(50))'")
                return
            }
            debugLog("[CM] chatSentence: '\(sentence.prefix(50))' (hasSentTTS=\(hasSentTTS))")
            state = .speaking
            hasSentTTS = true
            enqueueTTS(sentence)
            
        case .chatFinal(let text):
            debugLog("[CM] chatFinal: \(text.count) chars, hasSentTTS=\(hasSentTTS), hashes=\(currentResponseSentenceHashes.count)")
            // De-duplicate: skip if we already processed final for this response
            guard !processingFinalDone else {
                debugLog("[CM] chatFinal SKIPPED (duplicate)")
                return
            }
            processingFinalDone = true
            
            // If no sentences were received yet (very short response), reset de-dup for this final
            if !isReceivingResponse {
                currentResponseSentenceHashes.removeAll()
            }
            
            if !text.isEmpty && text != "HEARTBEAT_OK" && text != "NO_REPLY" {
                messages.append(ChatMessage(content: text, isUser: false))
                if !hasSentTTS {
                    state = .speaking
                    enqueueTTS(text)
                }
            } else if !hasSentTTS {
                state = .idle
            }
            hasSentTTS = false
            isReceivingResponse = false
            // Signal end of sentences — pipeline will finish after playing remaining items
            // Set continuation to nil so next response creates a new pipeline
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
            if state != .speaking { state = .thinking }
            
        case .agentDone:
            print("[CM] agentDone (current state=\(state))")
            if state == .thinking { state = .idle }
            
        case .messageSent(let runId):
            _ = runId // Kept for future use
            
        case .sendFailed(let reason):
            showError(reason)
        }
    }
    
    // MARK: - Send Message
    
    func sendMessage(_ text: String) {
        sendMessage(text, images: [])
    }
    
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
                // Send each image as a separate message to stay under gateway's 512KB payload limit
                for (i, img) in images.enumerated() {
                    let msg: String
                    if i == 0 {
                        msg = text.isEmpty ? "请看这\(images.count > 1 ? "\(images.count)张" : "张")图片" : text
                    } else {
                        msg = "(续) 第\(i + 1)张图片"
                    }
                    let attachment = [["type": "image", "mimeType": img.mimeType, "fileName": img.fileName, "content": img.data.base64EncodedString()]]
                    debugLog("[CM] Sending image \(i + 1)/\(images.count), fileName=\(img.fileName)")
                    await connection.sendChatWithAttachments(msg, attachments: attachment)
                }
                debugLog("[CM] All \(images.count) image(s) sent")
            } else {
                await connection.sendChat(text)
            }
        }
    }
    
    // MARK: - TTS Pipeline (serial: fetch → play → next)
    
    /// Enqueue a sentence for TTS. Starts the pipeline if not running.
    private func enqueueTTS(_ sentence: String) {
        // Only the latest instance should speak
        guard ChatManager.latestInstanceId == instanceId else {
            debugLog("[TTS] enqueueTTS BLOCKED (stale instance \(instanceId.uuidString.prefix(8)))")
            return
        }
        debugLog("[TTS] enqueueTTS: '\(sentence.prefix(40))'")
        
        // Start pipeline on first sentence
        if ttsContinuation == nil {
            startTTSPipeline()
        }
        
        ttsContinuation?.yield(sentence)
    }
    
    /// Creates an AsyncStream and a Task that serially processes each sentence using system TTS.
    private func startTTSPipeline() {
        let stream = AsyncStream<String> { continuation in
            self.ttsContinuation = continuation
        }
        
        // Cancel previous pipeline instead of waiting (prevents deadlock)
        ttsPipelineTask?.cancel()
        let previousTask = ttsPipelineTask
        
        ttsPipelineTask = Task { [weak self] in
            // Brief wait for previous pipeline to clean up
            if previousTask != nil {
                try? await Task.sleep(for: .milliseconds(200))
            }
            
            for await sentence in stream {
                guard let self else { break }
                await self.speakWithSystem(sentence)
            }
            
            // Pipeline finished
            guard let self else { return }
            debugLog("[TTS] Pipeline finished")
            self.ttsContinuation = nil
            self.ttsPipelineTask = nil
            if self.state == .speaking {
                self.state = .idle
            }
        }
    }
    
    /// Speak text using AVSpeechSynthesizer and suspend until done.
    /// Reuses a single synthesizer instance to avoid audio pipeline churn.
    private func speakWithSystem(_ text: String) async {
        // Strip emoji before speaking
        let cleanText = text.unicodeScalars.filter { scalar in
            !scalar.properties.isEmoji || scalar.properties.isASCIIHexDigit
        }.map(String.init).joined()
        
        // Skip empty text (e.g. emoji-only sentences)
        guard !cleanText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            debugLog("[TTS] Skipping empty/emoji-only text: '\(text.prefix(20))'")
            return
        }
        
        let utterance = AVSpeechUtterance(string: cleanText)
        // Prefer premium voices, fall back to lower quality
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
        
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Lazily create synthesizer, reuse for subsequent utterances
            if self.systemSynth == nil {
                self.systemSynth = AVSpeechSynthesizer()
            }
            let synth = self.systemSynth!
            let delegate = SystemSpeechDelegate {
                debugLog("[TTS] System speech finished")
                continuation.resume()
            }
            self.systemSynthDelegate = delegate
            synth.delegate = delegate
            synth.speak(utterance)
        }
    }
    
    /// Stop the TTS pipeline and clean up.
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
    
    private func setupWhisperKit() async {
        debugLog("[Whisper] Loading WhisperKit model...")
        
        // Local models directory (user-configurable)
        let localModelsBase = URL(fileURLWithPath: modelBasePath)
        
        // Try models from best accuracy to smallest fallback
        let modelsToTry = ["large-v3", "small", "base", "tiny"]
        
        for modelName in modelsToTry {
            let modelFolder = localModelsBase.appendingPathComponent("openai_whisper-\(modelName)")
            let useLocal = FileManager.default.fileExists(atPath: modelFolder.path)
            
            do {
                debugLog("[Whisper] Trying model: \(modelName) (local=\(useLocal))...")
                let config: WhisperKitConfig
                if useLocal {
                    config = WhisperKitConfig(modelFolder: modelFolder.path, verbose: true, logLevel: .debug)
                } else {
                    config = WhisperKitConfig(model: modelName)
                }
                whisperKit = try await WhisperKit(config)
                whisperReady = true
                debugLog("[Whisper] ✅ Model '\(modelName)' loaded successfully!")
                await MainActor.run { self.isMainModelLoaded = true }
                
                // Notify user on main thread
                await MainActor.run {
                    messages.append(ChatMessage(content: "🎤 语音模型 (\(modelName)) 已加载", isUser: false))
                }
                return
            } catch {
                debugLog("[Whisper] ❌ Model '\(modelName)' failed: \(error.localizedDescription)")
            }
        }
        
        debugLog("[Whisper] All models failed to load!")
        await MainActor.run {
            messages.append(ChatMessage(content: "⚠️ 语音模型加载失败，请检查网络连接", isUser: false))
        }
    }
    
    // MARK: - Speech Recognition (WhisperKit)
    
    func startListening() {
        let micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
        debugLog("[Speech] Mic auth=\(micAuth.rawValue)")
        
        // Request microphone permission if not yet determined
        if micAuth == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                debugLog("[Speech] Mic permission result: \(granted)")
                Task { @MainActor in
                    self.startListening()
                }
            }
            return
        }
        
        guard whisperReady else {
            debugLog("[Speech] WhisperKit not ready yet")
            messages.append(ChatMessage(content: "⚠️ 语音模型加载中，请稍等...", isUser: false))
            // Restore wake detector since we can't start listening
            isVoiceWakeTriggered = false
            state = .idle
            return
        }
        
        // Stop TTS if playing to avoid audio conflict
        systemSynth?.stopSpeaking(at: .immediate)
        
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        
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
        
        var tapCount = 0
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Extract Float samples from buffer (mono, channel 0)
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
            self.recordedSamples.append(contentsOf: samples)

            tapCount += 1
            var rms: Float = 0
            for i in 0..<frameLength {
                rms += channelData[i] * channelData[i]
            }
            rms = sqrtf(rms / Float(frameLength))
            
            // Track peak RMS during recording
            if rms > self.peakRmsDuringRecording {
                self.peakRmsDuringRecording = rms
            }

            if tapCount <= 3 || tapCount % 100 == 0 {
                debugLog("[Speech] Audio tap #\(tapCount): frames=\(frameLength), totalSamples=\(self.recordedSamples.count), rms=\(String(format: "%.6f", rms))")
            }

            // VAD auto-stop: when recording was triggered by wake word,
            // auto-stop after sustained silence
            if self.isVoiceWakeTriggered {
                Task { @MainActor [weak self] in
                    self?.checkVADAutoStop(rms: rms)
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
    
    private var recordingStartTime: Date?
    private let maxRecordingDuration: TimeInterval = 30.0  // Max 30 seconds
    
    private func checkVADAutoStop(rms: Float) {
        guard state == .listening, isVoiceWakeTriggered else { return }

        // Safety: force stop if recording too long
        if let start = recordingStartTime, Date().timeIntervalSince(start) >= maxRecordingDuration {
            debugLog("[Speech] VAD auto-stop: max recording duration reached (\(maxRecordingDuration)s)")
            stopListeningAndSend()
            return
        }

        if rms < vadAutoStopEnergyThreshold {
            if vadSilenceStart == nil {
                vadSilenceStart = Date()
            } else if Date().timeIntervalSince(vadSilenceStart!) >= vadAutoStopSilenceDuration {
                debugLog("[Speech] VAD auto-stop triggered after \(vadAutoStopSilenceDuration)s silence")
                stopListeningAndSend()
            }
        } else {
            vadSilenceStart = nil
        }
    }

    /// Stop listening and automatically transcribe + send (used by wake word flow).
    private func stopListeningAndSend() {
        guard state == .listening else { return }
        let wasWakeTriggered = isVoiceWakeTriggered
        let peakRms = peakRmsDuringRecording
        isVoiceWakeTriggered = false
        
        // Check if anyone actually spoke — discard if just background noise
        if peakRms < minSpeechRms {
            debugLog("[Speech] 🚫 丢弃录音 — 峰值 rms \(String(format: "%.4f", peakRms)) < \(minSpeechRms)，判定为背景噪音")
            recordedSamples.removeAll()  // Clear samples to prevent unnecessary transcription
            stopListening()
            state = .idle
            return
        }
        
        stopListening()

        if wasWakeTriggered {
            Task { @MainActor in
                // Wait for transcription
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if !currentTranscription.isEmpty { break }
                }
                if !currentTranscription.isEmpty {
                    let text = currentTranscription
                    currentTranscription = ""
                    // Play send sound
                    if let sound = NSSound(contentsOfFile: "/System/Library/Sounds/Submarine.aiff", byReference: true) {
                        sound.play()
                    }
                    sendMessage(text)
                }
            }
        }
    }

    func stopListening() {
        guard state == .listening else { return }
        
        debugLog("[Speech] Stopping recording, totalSamples=\(recordedSamples.count)")
        
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        
        state = .idle
        
        // Capture samples and transcribe with WhisperKit
        let samples = recordedSamples
        recordedSamples.removeAll()
        
        guard !samples.isEmpty else {
            debugLog("[Speech] No audio samples recorded")
            return
        }
        
        // Resample to 16kHz (Whisper's expected sample rate)
        let inputSampleRate = audioEngine.inputNode.outputFormat(forBus: 0).sampleRate
        let targetSampleRate: Double = 16000.0
        let resampledSamples: [Float]
        
        if abs(inputSampleRate - targetSampleRate) > 1.0 {
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
            resampledSamples = samples
        }
        
        let durationSec = Double(resampledSamples.count) / targetSampleRate
        debugLog("[Speech] Transcribing \(String(format: "%.1f", durationSec))s of audio with WhisperKit...")
        
        Task { @MainActor in
            do {
                let options = DecodingOptions(
                    task: .transcribe,
                    language: "zh",
                    temperature: 0.0,
                    sampleLength: 224,
                    chunkingStrategy: .vad
                )
                let results = try await whisperKit?.transcribe(audioArray: resampledSamples, decodeOptions: options)
                var text = results?.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                
                // Strip hallucination tails (e.g. "阿姨:阿姨,你吃吧")
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
    
    /// Strip hallucination tails from Whisper transcription.
    /// Whisper often appends fake dialogue, subtitles, or repeated phrases at the end.
    static func stripHallucinationTail(_ text: String) -> String {
        var result = text
        
        // Common hallucination phrases that Whisper appends at the end
        let tailPhrases = [
            "谢谢大家", "谢谢观看", "感谢观看", "感谢收看", "感谢收听",
            "谢谢你的观看", "谢谢你的收看",
            "请不吝点赞", "订阅转发", "点赞订阅",
            "阿姨你吃吧", "阿姨吃吧",
            "please subscribe", "thank you for watching", "like and subscribe",
            "thanks for watching"
        ]
        
        // Strip hallucination phrases from the end (with or without separator)
        let lower = result.lowercased()
        for phrase in tailPhrases {
            let p = phrase.lowercased()
            if lower.hasSuffix(p) && lower.count > p.count {
                result = String(result.dropLast(phrase.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                // Also strip trailing separator if present
                while result.hasSuffix(":") || result.hasSuffix("：") || result.hasSuffix("。") || result.hasSuffix("|") || result.hasSuffix(",") || result.hasSuffix("，") {
                    result = String(result.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                break
            }
        }
        
        // Check for hallucination after separator
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
        
        // Filter if ENTIRE text is a hallucination
        let finalLower = result.lowercased()
        let fullHallucinations = ["字幕", "订阅", "点赞", "转发", "谢谢", "谢谢大家", "(笑)", "(拍)", "♪"]
        for h in fullHallucinations {
            if finalLower == h.lowercased() { return "" }
        }
        
        return result
    }
    
    // MARK: - Error Handling
    
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

enum ConnectionEvent {
    case connected
    case disconnected(String)
    case connectionFailed(String)
    case chatSentence(String)   // A complete sentence ready for TTS
    case chatFinal(String)      // Remaining text after last sentence
    case chatAborted
    case chatError(String)
    case agentThinking
    case agentDone
    case messageSent(String?)
    case sendFailed(String)
}

// MARK: - WebSocket Connection (runs off main actor)

/// Handles all WebSocket communication and TTS networking off the main thread.
actor WebSocketConnection {
    struct Config: Sendable {
        let gatewayURL: String
        let gatewayToken: String
        let deviceToken: String
        let sessionKey: String
        let protocolVersion: Int
        let elevenLabsApiKey: String
        let elevenLabsVoiceId: String
        let deviceId: String
        let devicePublicKeyPem: String
        let devicePrivateKeyPem: String
    }
    
    let config: Config
    private var _onEvent: (@Sendable (ConnectionEvent) -> Void)?
    
    func setOnEvent(_ handler: @escaping @Sendable (ConnectionEvent) -> Void) {
        _onEvent = handler
    }
    
    private func emit(_ event: ConnectionEvent) {
        _onEvent?(event)
    }
    
    private enum PendingRequestType {
        case connect
        case chat
    }
    
    private var webSocket: URLSessionWebSocketTask?
    private var requestId = 0
    private var pendingRequests: [String: PendingRequestType] = [:]
    private var currentResponseBuffer = ""
    private var ttsSentIndex = 0  // How far into currentResponseBuffer we've sent to TTS
    private var challengeNonce: String?
    
    private static let sentenceEnders: CharacterSet = CharacterSet(charactersIn: "。！？；\n.!?;")
    
    init(config: Config) {
        self.config = config
    }
    
    private var shouldReconnect = true
    private var reconnectAttempt = 0
    
    // MARK: - Connect
    
    func connect() async {
        shouldReconnect = true
        reconnectAttempt = 0
        await doConnect()
    }
    
    private func doConnect() async {
        guard var urlComponents = URLComponents(string: config.gatewayURL) else { return }
        
        if !config.gatewayToken.isEmpty {
            urlComponents.queryItems = [URLQueryItem(name: "token", value: config.gatewayToken)]
        }
        
        guard let url = urlComponents.url else { return }
        
        // Reset state for fresh connection
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
    
    private func receiveLoop() async {
        while let ws = webSocket {
            do {
                let message = try await ws.receive()
                reconnectAttempt = 0  // reset on successful receive
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
                
                // Auto-reconnect with backoff
                if shouldReconnect {
                    reconnectAttempt += 1
                    let delay = min(Double(reconnectAttempt) * 2.0, 30.0)  // 2s, 4s, 6s... max 30s
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
    
    func sendChat(_ text: String) {
        let id = nextRequestId()
        let idempotencyKey = UUID().uuidString
        
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
    
    func sendChatWithAttachments(_ text: String, attachments: [[String: String]]) {
        let id = nextRequestId()
        let idempotencyKey = UUID().uuidString
        
        // Build attachments as [String: Any] to ensure correct JSON serialization
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
        
        // Debug: check if serialization works and log payload size
        if let data = try? JSONSerialization.data(withJSONObject: request) {
            let totalSize = data.count
            // Also log the first attachment's content length for debugging
            let contentLen = attachments.first?["content"]?.count ?? 0
            debugLog("[WS] sendChatWithAttachments: total=\(totalSize) bytes, attachments=\(anyAttachments.count), b64ContentLen=\(contentLen)")
            
            // Verify the JSON contains the attachments key
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
    
    private func nextRequestId() -> String {
        requestId += 1
        return "req-\(requestId)"
    }
    
    private func sendConnect() {
        let id = nextRequestId()
        
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
        
        // Use device token if available, fall back to gateway token
        if !config.deviceToken.isEmpty {
            params["auth"] = ["deviceToken": config.deviceToken, "token": config.gatewayToken]
        } else if !config.gatewayToken.isEmpty {
            params["auth"] = ["token": config.gatewayToken]
        }
        
        // Skip device identity for local connections — gateway token is sufficient
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
    
    /// Sign the challenge nonce with the device's Ed25519 private key.
    /// Returns a base64-encoded signature string.
    private func signChallenge(nonce: String, signedAt: Int64) -> String? {
        // Parse PEM to raw key bytes
        guard let privateKey = parseEd25519PrivateKey(pem: config.devicePrivateKeyPem) else {
            debugLog("[WS] signChallenge: failed to parse private key")
            return nil
        }
        
        // v2 signature payload: "v2|deviceId|clientId|clientMode|role|scopes|signedAtMs|token|nonce"
        // Gateway verifies with: auth.token ?? auth.deviceToken, so use gatewayToken here
        let scopes = "operator.admin,operator.read"
        let payload = "v2|\(config.deviceId)|openclaw-macos|ui|operator|\(scopes)|\(signedAt)|\(config.gatewayToken)|\(nonce)"
        
        debugLog("[WS] signChallenge payload: \(payload.prefix(120))...")
        
        guard let payloadData = payload.data(using: .utf8) else { return nil }
        guard let signature = try? privateKey.signature(for: payloadData) else { return nil }
        return signature.base64EncodedString()
    }
    
    /// Parse a PEM-encoded Ed25519 private key into a CryptoKit Curve25519 signing key.
    private func parseEd25519PrivateKey(pem: String) -> Curve25519.Signing.PrivateKey? {
        // Strip PEM headers/footers and decode base64
        let stripped = pem
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)
        
        guard let derData = Data(base64Encoded: stripped) else { return nil }
        
        // PKCS#8 wrapping for Ed25519: the raw 32-byte key starts at offset 16
        // DER structure: SEQUENCE { SEQUENCE { OID(ed25519) }, OCTET STRING { OCTET STRING { key } } }
        if derData.count == 48 {
            let rawKey = derData.suffix(32)
            return try? Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
        } else if derData.count == 32 {
            return try? Curve25519.Signing.PrivateKey(rawRepresentation: derData)
        }
        return nil
    }
    
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
    
    private func handleEvent(_ json: [String: Any]) {
        guard let event = json["event"] as? String,
              let payload = json["payload"] as? [String: Any] else {
            return
        }
        
        switch event {
        case "connect.challenge":
            challengeNonce = payload["nonce"] as? String
            sendConnect()
        case "chat":
            handleChatEvent(payload)
        case "agent":
            handleAgentEvent(payload)
        case "tick":
            break
        default:
            break
        }
    }
    
    private func handleChatEvent(_ payload: [String: Any]) {
        guard let stateStr = payload["state"] as? String else { return }
        
        switch stateStr {
        case "delta":
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
            // Prefer the final payload's text (it's the authoritative complete text)
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
            // Fall back to delta buffer if final payload had no text
            if finalText.isEmpty {
                finalText = currentResponseBuffer
            }
            
            // Send any remaining text that didn't end with a sentence ender
            let remaining = String(finalText.dropFirst(ttsSentIndex)).trimmingCharacters(in: .whitespacesAndNewlines)
            debugLog("[WS] final: total=\(finalText.count) chars, buffer=\(currentResponseBuffer.count) chars, remaining='\(remaining.prefix(80))'")
            if !remaining.isEmpty {
                emit(.chatSentence(remaining))
            }
            
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
    
    /// Scans the response buffer for complete sentences and emits them for TTS
    private func extractSentences() {
        let chars = Array(currentResponseBuffer)
        guard chars.count > ttsSentIndex else { return }
        
        // Scan from ttsSentIndex forward looking for sentence enders
        var lastSplit = ttsSentIndex
        for i in ttsSentIndex..<chars.count {
            let ch = chars[i]
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
        ttsSentIndex = lastSplit
    }
    
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

class SystemSpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onFinish: (() -> Void)?
    
    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish?()
        onFinish = nil
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        debugLog("[TTS] System speech cancelled")
        onFinish?()
        onFinish = nil
    }
}

// MARK: - String Language Detection

private extension String {
    /// Returns true if the string contains any CJK Unified Ideograph (Chinese character).
    var containsChinese: Bool {
        contains { ch in
            guard let scalar = ch.unicodeScalars.first else { return false }
            // CJK Unified Ideographs: U+4E00–U+9FFF
            // CJK Extension A: U+3400–U+4DBF
            return (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
        }
    }
}

// MARK: - Color Hex Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
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
