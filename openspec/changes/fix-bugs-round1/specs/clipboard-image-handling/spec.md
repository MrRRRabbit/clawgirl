## ADDED Requirements

### Requirement: Pasted images SHALL have correct MIME type

当用户通过 ⌘V 粘贴图片时，系统 SHALL 根据实际的 pasteboard 数据类型设置正确的 MIME 类型。PNG 数据标记为 `image/png`，TIFF 数据标记为 `image/tiff`。

#### Scenario: Pasting a PNG image from clipboard
- **WHEN** 用户粘贴一张 PNG 格式的图片
- **THEN** 创建的 `ImageAttachment` 的 `mimeType` 为 `"image/png"`

#### Scenario: Pasting a TIFF image from clipboard
- **WHEN** 用户粘贴一张 TIFF 格式的图片（且剪贴板上无 PNG 数据）
- **THEN** 创建的 `ImageAttachment` 的 `mimeType` 为 `"image/tiff"`
