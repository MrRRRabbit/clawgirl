## Why

Clawgirl 代码中存在几个明确的 bug 和代码质量问题，会导致潜在的崩溃（音频线程 data race）、错误的数据标记（MIME 类型 bug）以及不必要的性能开销（配置文件重复读取）。这些问题需要在添加新功能之前修复。

## What Changes

- 修复粘贴图片时 TIFF 格式被错误标记为 `image/png` 的 MIME 类型 bug
- 修复 `ChatManager.startListening()` 中音频 tap 回调直接在音频渲染线程访问 `@MainActor` 属性的 data race 问题，改为通过 `Task { @MainActor }` 安全访问
- 合并 `loadOpenClawConfig()` 中对 `openclaw.json` 的重复读取，一次读取同时提取 gateway token 和 ElevenLabs API key

## Capabilities

### New Capabilities

- `clipboard-image-handling`: 剪贴板图片粘贴与附件处理的正确性
- `audio-thread-safety`: 音频录音过程中的线程安全保证
- `config-loading`: OpenClaw 配置文件的加载逻辑

### Modified Capabilities

（无已有 capability 需要修改）

## Impact

- `ContentView.swift`: `handlePasteImages()` 中 MIME 类型修正
- `ChatManager.swift`: `startListening()` 音频 tap 闭包重构；`loadOpenClawConfig()` 合并读取逻辑；新增 `audioTapCount` 实例属性
