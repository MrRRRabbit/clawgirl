## ADDED Requirements

### Requirement: Audio tap callback SHALL NOT access MainActor properties directly

`AVAudioEngine.inputNode.installTap` 的回调在音频渲染线程执行。所有对 `@MainActor` 隔离属性（如 `recordedSamples`、`peakRmsDuringRecording`、`audioTapCount`）的访问 SHALL 通过 `Task { @MainActor }` 调度，避免 data race。

#### Scenario: Recording audio samples during voice input
- **WHEN** 音频 tap 回调在音频渲染线程收到新的 PCM 数据
- **THEN** 样本提取和 RMS 计算在音频线程完成，但 `recordedSamples.append`、`peakRmsDuringRecording` 更新和 `checkVADAutoStop` 调用均在 MainActor 上执行

### Requirement: Audio buffer data SHALL be extracted before MainActor dispatch

`AVAudioPCMBuffer` 的 `floatChannelData` 仅在 tap 回调执行期间有效。系统 SHALL 在回调中先将样本复制到独立的 `[Float]` 数组，再传递给 `Task { @MainActor }` 闭包。

#### Scenario: Buffer validity during async dispatch
- **WHEN** tap 回调收到 `AVAudioPCMBuffer`
- **THEN** 在创建 `Task { @MainActor }` 之前，已通过 `Array(UnsafeBufferPointer(...))` 将样本数据复制到独立数组
