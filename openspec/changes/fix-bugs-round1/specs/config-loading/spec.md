## ADDED Requirements

### Requirement: OpenClaw config file SHALL be read only once per load

`loadOpenClawConfig()` SHALL 对 `~/.openclaw/openclaw.json` 只执行一次文件读取和 JSON 解析，从同一个解析结果中提取所有需要的配置项（gateway token、ElevenLabs API key 等）。

#### Scenario: Loading config with both gateway token and ElevenLabs key
- **WHEN** `openclaw.json` 包含 `gateway.auth.token` 和 `tools.tts.elevenLabsApiKey`
- **THEN** 两个值均从同一次文件读取和 JSON 解析中提取，不重复读取文件

#### Scenario: Loading config with only gateway token
- **WHEN** `openclaw.json` 包含 `gateway.auth.token` 但没有 `tools.tts` 配置
- **THEN** `gatewayToken` 正确提取，`elevenLabsApiKey` 为空字符串
