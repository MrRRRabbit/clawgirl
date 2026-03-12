## 1. MIME 类型修复

- [x] 1.1 修复 `ContentView.swift` 中 `handlePasteImages()` 的 MIME 类型三元表达式，TIFF 数据返回 `"image/tiff"`

## 2. 音频线程安全修复

- [x] 2.1 将 `ChatManager.swift` 中 `startListening()` 的 audio tap 闭包内所有 `self` 属性访问移入 `Task { @MainActor }`
- [x] 2.2 将 `tapCount` 局部变量改为 `audioTapCount` 实例属性
- [x] 2.3 将 `checkVADAutoStop` 从嵌套 Task 改为直接调用（已在 MainActor 上下文中）

## 3. 配置文件合并读取

- [x] 3.1 合并 `loadOpenClawConfig()` 中对 `openclaw.json` 的两次读取为一次，同时提取 `gatewayToken` 和 `elevenLabsApiKey`

## 4. 验证

- [x] 4.1 确认项目编译通过（`xcodebuild build`）
