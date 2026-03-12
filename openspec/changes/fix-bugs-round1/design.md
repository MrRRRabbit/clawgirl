## Context

Clawgirl 是一个 macOS 原生语音对话 App，使用 WhisperKit 进行语音识别、AVSpeechSynthesizer 进行 TTS、WebSocket 连接 OpenClaw 网关。代码集中在四个 Swift 文件中，其中 `ChatManager.swift` 约 1570 行，承担了大部分逻辑。

当前存在三个明确的代码问题需要修复，均已在代码中完成实现。

## Goals / Non-Goals

**Goals:**
- 修复粘贴 TIFF 图片时 MIME 类型标记错误
- 消除音频录音 tap 回调中的 data race
- 消除 `loadOpenClawConfig()` 中对同一配置文件的重复读取

**Non-Goals:**
- 不进行架构重构（ChatManager 拆分留待后续）
- 不修改功能行为或 UI
- 不添加新功能

## Decisions

### 1. MIME 类型修正：直接修正三元表达式

将 `imageType == .png ? "image/png" : "image/png"` 改为 `imageType == .png ? "image/png" : "image/tiff"`。

**替代方案：** 将所有非 PNG 格式统一转换为 PNG 后再发送。放弃该方案，因为增加了不必要的转换开销，且服务端应能处理常见图片格式。

### 2. 音频线程安全：采用与 WakeWordDetector 一致的 `Task { @MainActor }` 模式

在音频线程中提取样本数据和计算 RMS（因为 `AVAudioPCMBuffer` 仅在回调期间有效），然后通过 `Task { @MainActor }` 将所有 `self` 属性访问调度到 MainActor。

**替代方案：** 使用独立的锁或队列保护 `recordedSamples`。放弃该方案，因为 WakeWordDetector 已有成功的同模式实现，保持一致性更好。

**影响：** `tapCount` 局部变量需改为实例属性 `audioTapCount`，因为 `Task { @MainActor }` Sendable 闭包无法捕获可变局部变量。VAD 自动停止的 `checkVADAutoStop` 调用从嵌套 Task 简化为直接调用（已在 MainActor 上下文中）。

### 3. 配置文件合并读取：一次解析提取多个值

将 `openclaw.json` 的两次独立读取合并为一次 `FileManager.contents` + `JSONSerialization` 调用，在同一个 `if let` 块中分别提取 `gatewayToken` 和 `elevenLabsApiKey`。

## Risks / Trade-offs

- **音频尾部样本丢失风险** → `stopListening()` 在 `audioEngine.stop()` 后同步读取 `recordedSamples`，此时可能有少量 `Task { @MainActor }` 回调尚未执行。影响极小（最多丢失一个 4096 帧的 buffer，约 0.08 秒），不影响识别质量。
- **TIFF MIME 类型兼容性** → 如果 OpenClaw 网关不支持 `image/tiff`，粘贴 TIFF 图片可能失败。但实际上 macOS 剪贴板通常同时提供 PNG 和 TIFF，代码优先检查 PNG，所以 TIFF 路径很少触发。
