// WakeWordDetector.swift
// Clawgirl
//
// 文件用途：唤醒词检测器，持续监听麦克风，识别用户说出特定唤醒词（"波波"/"小虾"等）。
// 核心功能：
//   1. 使用轻量级 WhisperKit tiny/base/small 模型进行本地语音转文字
//   2. 通过 VAD（Voice Activity Detection）判断有效语音片段，避免无效转写
//   3. 维护一个预缓冲区（pre-buffer）确保捕获完整词头部分
//   4. 检测到唤醒词后通知 ChatManager 启动正式录音
//   5. 支持暂停/恢复，避免与 ChatManager 正式录音或 TTS 播放冲突

import Foundation
import AVFoundation
import RealTimeCutVADLibrary
import WhisperKit

/// 唤醒词检测器
/// 使用轻量 WhisperKit 模型在后台持续监听唤醒词（"波波"/"小虾"系列）。
/// 拥有独立的 AVAudioEngine，在 ChatManager 录音或 TTS 播放期间自动暂停。
@MainActor
class WakeWordDetector {
    // MARK: - Configuration

    /// 单次最长监听时长：超过此时间强制结束并转写，防止无限等待
    private let maxListenDuration: TimeInterval = 3.0
    
    /// 默认唤醒词列表（包含"小虾"和"波波"的各种谐音/写法，提高召回率）
    static let defaultWakeWords = [
        // 小虾系列：正确写法 + Whisper 高频误转写变体
        "小虾", "小蝦",   // 简体/繁体
        "小夏",           // 最常见的 Whisper 转写
        "小瞎",           // 常见变体
        "小下", "小霞", "小侠", "小俠", "小香",  // 同音字变体
    ]
    
    /// 用户可自定义的唤醒词列表，持久化存储在 UserDefaults
    /// getter：优先读取用户保存的列表，为空则返回默认列表
    /// setter：将新列表写入 UserDefaults 持久化
    var wakeWords: [String] {
        get {
            if let saved = UserDefaults.standard.array(forKey: "wakeWords") as? [String], !saved.isEmpty {
                return saved
            }
            return Self.defaultWakeWords
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "wakeWords")
        }
    }

    // MARK: - State

    /// WhisperKit 语音转文字引擎实例（轻量模型）
    private var whisperKit: WhisperKit?

    /// WhisperKit 是否已加载完成，加载完成前不允许启动检测
    private var whisperReady = false

    /// 麦克风音频引擎，独立于 ChatManager 的录音引擎
    private var audioEngine = AVAudioEngine()

    /// 当前是否正在检测（audioEngine 已启动并安装了 tap）
    private var isDetecting = false

    /// 是否处于暂停状态（ChatManager 录音/TTS 期间暂停）
    var isPaused = false

    // VAD 相关状态（Silero VAD）

    /// Silero VAD 实例
    private let wakeVad: VADWrapper? = VADWrapper()
    /// VAD delegate 桥接
    private var wakeVadBridge: WakeVADDelegateBridge?

    /// 是否正在捕获一段语音
    private var isCapturing = false

    /// 当前捕获到的音频样本缓冲区
    private var capturedSamples: [Float] = []

    /// 本次语音片段开始捕获的时间
    private var captureStartTime: Date?

    /// 麦克风采样率（根据实际设备动态获取）
    private var inputSampleRate: Double = 48000.0

    /// 预缓冲区：保存最近约 0.5 秒的音频，避免语音词头被截断
    private var preBuffer: [Float] = []
    /// 预缓冲区长度（秒）
    private let preBufferDuration: Double = 0.5

    /// 检测到唤醒词时的回调，在主线程触发，通知 ChatManager 开始录音
    var onWakeWordDetected: (() -> Void)?

    /// 模型加载完成时的回调，用于更新 UI 加载状态
    var onModelLoaded: (() -> Void)?

    // MARK: - Init

    /// 初始化入口：异步加载 WhisperKit 轻量模型
    func setup() async {
        await loadTinyModel()
    }

    /// WhisperKit CoreML 模型根目录，可由外部（ChatManager）设置以支持自定义路径
    var modelBasePath: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/huggingface/models/argmaxinc/whisperkit-coreml").path
    
    /// 依次尝试加载 small → base → tiny 模型，优先本地缓存，降级到网络下载
    /// 成功加载后设置 whisperReady = true 并调用 onModelLoaded 回调
    private func loadTinyModel() async {
        let localModelsBase = URL(fileURLWithPath: modelBasePath)

        // 按精度从高到低降级尝试
        let modelsToTry = ["small", "base", "tiny"]
        for modelName in modelsToTry {
            let modelFolder = localModelsBase.appendingPathComponent("openai_whisper-\(modelName)")
            let useLocal = FileManager.default.fileExists(atPath: modelFolder.path)

            do {
                debugLog("[WakeWord] Trying model: \(modelName) (local=\(useLocal))...")
                let config: WhisperKitConfig
                if useLocal {
                    // 优先使用本地模型，避免网络依赖
                    config = WhisperKitConfig(modelFolder: modelFolder.path, verbose: false, logLevel: .error)
                } else {
                    // 本地不存在则从网络下载
                    config = WhisperKitConfig(model: modelName, verbose: false, logLevel: .error)
                }
                whisperKit = try await WhisperKit(config)
                whisperReady = true
                debugLog("[WakeWord] ✅ Tiny model '\(modelName)' loaded")
                onModelLoaded?()
                return
            } catch {
                debugLog("[WakeWord] ❌ Model '\(modelName)' failed: \(error.localizedDescription)")
            }
        }
        debugLog("[WakeWord] All wake-word models failed to load")
    }

    // MARK: - Start / Stop
    
    /// 请求麦克风权限（异步）
    /// - Returns: 用户是否授权麦克风访问
    func requestMicrophonePermission() async -> Bool {
        if #available(macOS 14.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    /// 启动唤醒词检测
    /// 安装音频 tap，开始实时处理麦克风输入
    func startDetecting() {
        // 模型未就绪、已在检测中或处于暂停状态时不启动
        guard whisperReady, !isDetecting else { return }
        guard !isPaused else { return }

        isDetecting = true
        // 重置 VAD 状态
        isCapturing = false
        capturedSamples.removeAll()
        captureStartTime = nil

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputSampleRate = recordingFormat.sampleRate

        // 配置 Silero VAD
        setupWakeVAD()

        // 安装音频 tap：PCM 数据喂给 Silero VAD，由 VAD 回调驱动捕获
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            // 在音频线程喂给 Silero VAD
            self?.wakeVad?.processAudioData(withBuffer: channelData, count: UInt(frameLength))
            // 同时在主线程收集样本（如果正在捕获）
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
            Task { @MainActor [weak self] in
                self?.collectSamples(samples)
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            debugLog("[WakeWord] Audio engine started, listening for wake word...")
        } catch {
            debugLog("[WakeWord] Audio engine failed: \(error)")
            isDetecting = false
        }
    }

    /// 配置唤醒词用的 Silero VAD
    private func setupWakeVAD() {
        wakeVad?.setSileroModel(.v5)
        // 根据实际采样率设置
        switch inputSampleRate {
        case 48000: wakeVad?.setSamplerate(.SAMPLERATE_48)
        case 24000: wakeVad?.setSamplerate(.SAMPLERATE_24)
        case 16000: wakeVad?.setSamplerate(.SAMPLERATE_16)
        default:    wakeVad?.setSamplerate(.SAMPLERATE_48)
        }
        // 唤醒词检测：灵敏触发、快速结束（短词）
        wakeVad?.setThresholdWithVadStartDetectionProbability(
            0.5,
            vadEndDetectionProbability: 0.5,
            voiceStartVadTrueRatio: 0.5,
            voiceEndVadFalseRatio: 0.8,
            voiceStartFrameCount: 5,     // ~160ms 确认语音开始
            voiceEndFrameCount: 16       // ~512ms 静音确认结束（唤醒词很短）
        )
        wakeVadBridge = WakeVADDelegateBridge(
            onVoiceStarted: { [weak self] in
                Task { @MainActor in self?.handleWakeVADVoiceStarted() }
            },
            onVoiceEnded: { [weak self] in
                Task { @MainActor in self?.handleWakeVADVoiceEnded() }
            }
        )
        wakeVad?.delegate = wakeVadBridge
    }

    /// 停止唤醒词检测，释放音频资源
    func stopDetecting() {
        guard isDetecting else { return }
        isDetecting = false
        isCapturing = false
        capturedSamples.removeAll()
        preBuffer.removeAll()

        // 停止并移除音频 tap
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        debugLog("[WakeWord] Stopped detecting")
    }

    /// 暂停检测（ChatManager 开始录音或播放 TTS 时调用）
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        stopDetecting()
        debugLog("[WakeWord] Paused")
    }

    /// 恢复检测（ChatManager 返回 idle 状态时调用）
    func resume() {
        guard isPaused else { return }
        isPaused = false
        debugLog("[WakeWord] Resumed")
        startDetecting()
    }

    // MARK: - Audio Processing (Silero VAD driven)

    /// 收集音频样本：捕获中则追加到 capturedSamples，否则维护预缓冲区
    private func collectSamples(_ samples: [Float]) {
        guard isDetecting else { return }

        if isCapturing {
            capturedSamples.append(contentsOf: samples)
            // 超时保护：超过最大时长强制结束
            if let start = captureStartTime, Date().timeIntervalSince(start) >= maxListenDuration {
                debugLog("[WakeWord] ⏱️ Max listen duration reached, forcing transcription")
                finishCapture()
            }
        } else {
            // 未捕获时维护滚动预缓冲区（保留最近 0.5 秒音频，避免词头截断）
            let maxPreBufferSamples = Int(inputSampleRate * preBufferDuration)
            preBuffer.append(contentsOf: samples)
            if preBuffer.count > maxPreBufferSamples {
                preBuffer.removeFirst(preBuffer.count - maxPreBufferSamples)
            }
        }
    }

    /// Silero VAD 检测到人声开始
    private func handleWakeVADVoiceStarted() {
        guard isDetecting, !isCapturing else { return }
        isCapturing = true
        // 将预缓冲区前置，确保词头不丢失
        capturedSamples = preBuffer
        preBuffer.removeAll()
        captureStartTime = Date()
        debugLog("[WakeWord] 👂 Silero VAD: voice started, capturing... (preBuffer: \(capturedSamples.count) samples)")
    }

    /// Silero VAD 检测到人声结束 → 触发转写
    private func handleWakeVADVoiceEnded() {
        guard isDetecting, isCapturing else { return }
        debugLog("[WakeWord] 👂 Silero VAD: voice ended, transcribing...")
        finishCapture()
    }

    /// 结束捕获并发起转写
    private func finishCapture() {
        let samplesToTranscribe = capturedSamples
        isCapturing = false
        capturedSamples.removeAll()
        captureStartTime = nil

        guard !samplesToTranscribe.isEmpty else { return }

        Task { @MainActor in
            await transcribeAndCheck(samplesToTranscribe)
        }
    }

    // MARK: - Transcription & Matching

    /// 将捕获的音频样本转写为文字，并检测是否包含唤醒词
    /// - Parameter samples: 待转写的 Float 音频样本数组（原始采样率）
    private func transcribeAndCheck(_ samples: [Float]) async {
        guard whisperReady, let whisper = whisperKit else { return }

        // WhisperKit 要求 16kHz 采样率，需要对原始音频进行线性插值重采样
        let targetSampleRate: Double = 16000.0
        let resampled: [Float]
        if abs(inputSampleRate - targetSampleRate) > 1.0 {
            // 使用线性插值实现简单重采样
            let ratio = targetSampleRate / inputSampleRate
            let outputLength = Int(Double(samples.count) * ratio)
            var buf = [Float](repeating: 0, count: outputLength)
            for i in 0..<outputLength {
                let srcIdx = Double(i) / ratio
                let idx = Int(srcIdx)
                let frac = Float(srcIdx - Double(idx))
                if idx + 1 < samples.count {
                    // 线性插值：在相邻两个样本之间插值
                    buf[i] = samples[idx] * (1 - frac) + samples[idx + 1] * frac
                } else if idx < samples.count {
                    buf[i] = samples[idx]
                }
            }
            resampled = buf
        } else {
            // 采样率已是 16kHz，无需重采样
            resampled = samples
        }

        let durationSec = Double(resampled.count) / targetSampleRate
        debugLog("[WakeWord] Transcribing \(String(format: "%.1f", durationSec))s...")

        do {
            // 不注入 promptTokens — 对 tiny/small 模型，过多 prompt tokens 会导致
            // 短音频片段返回空结果或严重幻听（如 "謝謝大家!"）
            let options = DecodingOptions(
                task: .transcribe,
                language: "zh",       // 指定中文，提高唤醒词识别准确率
                temperature: 0.0,     // 贪心解码，提高稳定性
                sampleLength: 224     // 短音频片段限制解码长度
            )
            let results = try await whisper.transcribe(audioArray: resampled, decodeOptions: options)

            // 详细日志：记录每个 segment 的原始文本，便于排查
            for (i, seg) in results.enumerated() {
                debugLog("[WakeWord] segment[\(i)]: '\(seg.text)'")
            }

            let text = results.map { $0.text }.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            // 过滤 Whisper 幻听（从噪音/静音中生成的假字幕）
            guard !isHallucination(text) else {
                debugLog("[WakeWord] ⏭️ 跳过幻听: '\(text)'")
                return
            }

            debugLog("[WakeWord] 👂 唤醒词检测: '\(text)' (不会发送)")

            // 检查转写结果是否匹配唤醒词
            if matchesWakeWord(text) {
                debugLog("[WakeWord] 🎯 Wake word detected!")
                // 立即停止检测，由 ChatManager 在录音结束后调用 resume() 恢复
                stopDetecting()
                onWakeWordDetected?()
            }
        } catch {
            debugLog("[WakeWord] Transcription error: \(error)")
        }
    }

    /// 检查文字是否包含任意唤醒词（不区分大小写，中英文标点已预处理去除）
    /// - Parameter text: 已 lowercased 的转写结果
    /// - Returns: 是否匹配到唤醒词
    private func matchesWakeWord(_ text: String) -> Bool {
        // 去除所有空格和常见标点，避免 WhisperKit 在中文字间插入空格导致匹配失败
        // 例如 WhisperKit 输出 "小 夏" 而唤醒词是 "小夏"
        let normalized = text.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "？", with: "")
            .replacingOccurrences(of: "！", with: "")
            .trimmingCharacters(in: .whitespaces)

        // 唤醒词匹配：要求转写结果足够短（唤醒词长度 + 容差）
        // 防止正常对话中偶然包含唤醒词导致误触发
        // 例如 "我就用小虾做煮花鲜吃吧" 包含 "小虾" 但不应触发
        for word in wakeWords {
            let w = word.lowercased().replacingOccurrences(of: " ", with: "")
            if normalized.contains(w) {
                // 转写长度不超过唤醒词长度 + 3 个字符的容差（允许语气词如 "小虾呀"）
                if normalized.count <= w.count + 3 {
                    return true
                } else {
                    debugLog("[WakeWord] ⚠️ 包含唤醒词但句子太长(\(normalized.count)字)，跳过: '\(normalized)'")
                }
            }
        }
        return false
    }
    
    /// 检测常见 Whisper 幻听模式（从静音/噪音中生成的假内容）
    /// - Parameter text: 待检测的转写文本
    /// - Returns: 是否为幻听内容（true 表示应丢弃）
    private func isHallucination(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 空内容 → 幻听
        if t.isEmpty { return true }
        
        // 常见幻听模式：字幕水印、频道推广、背景音效标注等
        let patterns = [
            "字幕", "订阅", "訂閱", "点赞", "點讚", "转发", "轉發",
            "打赏", "打賞", "感谢", "感謝", "谢谢", "謝謝",
            "明镜", "明鏡", "栏目", "欄目", "支持", "频道", "頻道",
            "(笑)", "(拍)", "(music)", "♪",
            "字幕:j", "chong", "字幕by",
            "please subscribe", "thank you", "like and subscribe"
        ]
        let lower = t.lowercased()
        for pattern in patterns {
            if lower.contains(pattern.lowercased()) {
                return true
            }
        }
        
        // 去括号后有效内容过短（≤1个字符）→ 视为噪音幻听
        let stripped = t.replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "（", with: "")
            .replacingOccurrences(of: "）", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.count <= 1 { return true }

        return false
    }
}

// MARK: - Wake VAD Delegate Bridge

/// 桥接 Silero VAD 回调到 WakeWordDetector（后台线程 → MainActor）
class WakeVADDelegateBridge: NSObject, VADDelegate {
    private let onVoiceStarted: () -> Void
    private let onVoiceEnded: () -> Void

    init(onVoiceStarted: @escaping () -> Void, onVoiceEnded: @escaping () -> Void) {
        self.onVoiceStarted = onVoiceStarted
        self.onVoiceEnded = onVoiceEnded
    }

    func voiceStarted() {
        onVoiceStarted()
    }

    func voiceEnded(withWavData wavData: Data!) {
        onVoiceEnded()
    }

    func voiceDidContinue(withPCMFloat pcmFloatData: Data!) {}
}
