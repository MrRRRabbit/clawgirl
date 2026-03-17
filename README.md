<p align="center">
  <img src="docs/images/banner.jpeg" alt="Clawgirl Banner" width="100%">
</p>

<h1 align="center">🦞 Clawgirl</h1>

<p align="center">
  A native macOS desktop companion for <a href="https://github.com/openclaw/openclaw">OpenClaw</a> AI agents<br>
  Voice wake · Real-time chat · Text-to-speech
</p>

<p align="center">
  <img src="docs/images/avatar_idle.png" alt="Idle" width="120">
  <img src="docs/images/avatar_listening.png" alt="Listening" width="120">
  <img src="docs/images/avatar_thinking.png" alt="Thinking" width="120">
  <img src="docs/images/avatar_speaking.png" alt="Speaking" width="120">
</p>

> Talk to your AI agent like talking to a friend. Say the wake word, speak naturally, and hear the response read back to you.

English | [中文](README_CN.md)

## ✨ Features

- **🎤 Voice Wake Word Detection** — Say "小虾" (or any custom wake word) to activate hands-free voice input, powered by Silero VAD + WhisperKit
- **🗣️ Speech-to-Text** — Powered by [WhisperKit](https://github.com/argmaxinc/WhisperKit) (on-device, no cloud API needed), with Silero VAD for intelligent auto-stop
- **🔊 Text-to-Speech** — Hear AI responses read aloud with configurable macOS voices
- **💬 Real-time Chat** — WebSocket connection to your OpenClaw gateway with streaming responses
- **🖼️ Image Support** — Drag & drop or paste images to send with your messages
- **🌊 Beautiful UI** — Ocean blue theme with state-aware animations (idle ripple, listening waves, thinking dots, speaking bars)
- **⌨️ Customizable Keyboard Shortcuts** — `⌘D` push-to-talk, `⌘E` toggle wake (default, customizable in settings). Supports combo keys, single keys, and modifier-only shortcuts (e.g., `⌥`)
- **📊 Loading Indicator** — Shows model loading progress on startup with status dots
- **🔒 Microphone Permission** — Explicit permission request on first use
- **⚙️ Fully Configurable** — Gateway URL, token, session, wake words, model path, TTS voice — all in the settings panel

## 📋 Requirements

- **macOS 14.0+** (Sonoma or later)
- **Apple Silicon** (M1/M2/M3/M4) — required for WhisperKit CoreML models
- **Xcode 16+** — to build the project
- **Node.js 18+** — required by OpenClaw (install via [fnm](https://github.com/Schniz/fnm), [nvm](https://github.com/nvm-sh/nvm), or [Homebrew](https://brew.sh))
- **[OpenClaw](https://github.com/openclaw/openclaw)** — fully installed and configured on your machine (see below)

## 🚀 Quick Start

### 1. Install & configure OpenClaw

Clawgirl is a desktop frontend for [OpenClaw](https://github.com/openclaw/openclaw). You need a fully working OpenClaw installation before using Clawgirl:

```bash
# Install OpenClaw globally
npm install -g openclaw

# Run initial setup (creates ~/.openclaw/ config directory)
openclaw setup

# Start the gateway (default port 18789)
openclaw gateway start
```

After setup, OpenClaw creates the following files that Clawgirl reads automatically:

| File | Purpose |
|------|---------|
| `~/.openclaw/openclaw.json` | Gateway token (auto-loaded on first launch) |
| `~/.openclaw/agents/main/sessions/sessions.json` | Session list (populates the session picker) |

> **Note:** The gateway must be running for Clawgirl to connect. You can check status with `openclaw gateway status` and restart from the app's settings panel.

### 2. Clone the repo

```bash
git clone https://github.com/MrRRRabbit/clawgirl.git
cd clawgirl
```

### 3. Download WhisperKit models

Clawgirl uses WhisperKit for on-device speech recognition. You need to download the CoreML models first:

```bash
# Install huggingface-cli if you don't have it
pip install huggingface_hub

# Download models (small for wake word, large-v3 for transcription)
huggingface-cli download argmaxinc/whisperkit-coreml \
  --include "openai_whisper-small/*" "openai_whisper-large-v3/*" \
  --local-dir ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml
```

> **💡 Tip:** If you're in China, use the mirror:
> ```bash
> HF_ENDPOINT=https://hf-mirror.com huggingface-cli download argmaxinc/whisperkit-coreml \
>   --include "openai_whisper-small/*" "openai_whisper-large-v3/*" \
>   --local-dir ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml
> ```

> **💡 Tip:** If you want faster startup and don't need high accuracy, you can use `openai_whisper-base` or `openai_whisper-small` only. The app will automatically fall back to smaller models.

### 4. Build & Run

Open `Clawgirl.xcodeproj` in Xcode, then:

1. Wait for Swift Package Manager to resolve dependencies (WhisperKit + RealTimeCutVADLibrary)
2. Select your Mac as the run destination
3. Press `⌘R` to build and run

### 5. Configure

Click the ⚙️ gear icon in the app to configure:

| Setting | Description | Default |
|---------|-------------|---------|
| **Gateway URL** | Your OpenClaw gateway WebSocket address | `ws://127.0.0.1:18789` |
| **Gateway Token** | Authentication token from `~/.openclaw/openclaw.json` | Auto-detected |
| **Session** | Which OpenClaw session to use (dropdown, auto-loaded from `~/.openclaw`) | `main` |
| **Model Path** | Where WhisperKit CoreML models are stored | `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml` |
| **Wake Words** | Words that trigger voice input | 小虾, 小夏, 小瞎, ... |
| **TTS Voice** | Chinese and English TTS voices (select from macOS voices) | Wing (Premium) |

> **Note:** The gateway token is automatically loaded from your local OpenClaw config (`~/.openclaw/openclaw.json`) on first launch. You only need to set it manually if you're connecting to a remote gateway.

> **Note:** Gateway URL and Token changes require an app restart to take effect. Session switching works immediately.

## 🎙️ How Voice Wake Works

```
┌─────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────┐
│  Always-on   │     │  🔔 Alert    │     │  🎤 Record   │     │  📤 Send │
│  Listening   │────▶│  Sound       │────▶│  Your Voice  │────▶│  Message │
│  (Silero VAD │     │  (Glass.aiff)│     │  (large-v3)  │     │          │
│  + small model)    └──────────────┘     └──────────────┘     └──────────┘
└─────────────┘                                 │                    │
       │                                  Silero VAD            🔔 Submarine
       │ Say "小虾"                     auto-stop (~3s)         sound plays
       ▼                                        ▼                    ▼
  Silero VAD detects voice              WhisperKit large-v3    AI responds
  → WhisperKit small                   (full transcription)    with TTS
  (wake word only, never sent)
```

1. **Idle** — Silero VAD (neural network) continuously monitors microphone; when voice is detected, WhisperKit `small` checks for wake word
2. **Wake** — Wake word detected → plays Glass alert sound → waits 500ms
3. **Record** — Records your speech with Silero VAD auto-stop (~3s silence detection, neural network based)
4. **Send** — Transcribes with WhisperKit `large-v3` → plays Submarine sound → sends to OpenClaw
5. **Reply** — AI response streams in → displayed in chat → read aloud via TTS
6. **Resume** — Returns to wake word listening

## ⌨️ Keyboard Shortcuts

Press `⌘/` in the app or click the ⌨️ icon to see all shortcuts.

| Shortcut | Action | Customizable |
|----------|--------|:---:|
| `⌘ D` | Push-to-talk (press to record, press again to send) | ✅ |
| `⌘ E` | Toggle voice wake word detection on/off | ✅ |
| `⌘ V` | Paste image from clipboard | |
| `⌘ /` | Show keyboard shortcuts help | |
| `Enter` | Send text message | |
| `Shift + Enter` | Insert new line | |

> **Tip:** You can customize Push-to-talk and Voice Wake shortcuts in the ⚙️ settings panel. Supported formats: combo keys (`⌘D`, `⌃⇧E`), single keys (`F`), and modifier-only (`⌥`).

## 🎨 State Animations

The app shows different animations below the avatar based on the current state:

| State | Animation | Color |
|-------|-----------|-------|
| 🌊 Idle | Water ripple rings | Ocean blue |
| 👂 Listening | Jumping audio bars | Turquoise |
| 🤔 Thinking | Bouncing dots | Warm sand |
| 🗣️ Speaking | Pulsing sound bars | Coral |
| ❌ Error | Red pulse | Red |

## 📁 Project Structure

```
clawgirl/
├── Clawgirl.xcodeproj/
├── Clawgirl/
│   ├── ClawgirlApp.swift          # App entry point
│   ├── ContentView.swift           # Main UI + settings panel
│   ├── ChatManager.swift           # Core logic: chat, TTS, WebSocket, WhisperKit, Silero VAD
│   ├── WakeWordDetector.swift      # Wake word detection with Silero VAD + WhisperKit small
│   ├── DebugLog.swift              # Debug logging utility (console + file)
│   ├── Info.plist                  # App permissions (microphone)
│   ├── Clawgirl.entitlements       # Audio input entitlement
│   └── Assets/                     # Avatar expression PNGs
│       ├── idle.png
│       ├── idle_blink.png
│       ├── listening.png
│       ├── thinking.png
│       ├── speaking_1.png
│       └── speaking_2.png
└── README.md
```

## 🔧 Troubleshooting

### App shows "正在加载语音模型..."
WhisperKit CoreML models need to compile on first launch. This takes:
- **small model** (wake word): ~30 seconds
- **large-v3 model** (transcription): ~2.5 minutes

Subsequent launches will be much faster (compiled models are cached).

### No microphone icon in menu bar
The app needs microphone permission. If the system prompt didn't appear:
1. Open **System Settings → Privacy & Security → Microphone**
2. Enable Clawgirl

### TTS voice sounds robotic
Clawgirl defaults to **Wing** (Premium, Chinese - Hong Kong), which handles both Chinese and English well. If you haven't downloaded this voice:
1. Open **System Settings → Accessibility → Spoken Content → System Voice → Manage Voices...**
2. Search for "Wing" (Chinese - Hong Kong) and click the download button
3. You can also download other Premium/Enhanced voices and select them in the app's settings

The app will fall back to available system voices if the configured voice isn't installed.

### Wake word not detecting
- Check that the 👂 ear icon is active (turquoise)
- Check the ⚙️ settings panel — wake model status should be 🟢
- The default wake word "小虾" (and variants 小夏/小瞎) has the best recognition accuracy
- Try speaking clearly and at normal volume — Silero VAD handles soft speech well
- Wearing headphones may reduce mic sensitivity

### "已损坏" or can't open the app
For unsigned builds, run:
```bash
xattr -cr /path/to/Clawgirl.app
```

### Gateway connection failed
- Ensure OpenClaw gateway is running (`openclaw gateway status`)
- Check the gateway URL and token in ⚙️ settings
- Default gateway port is `18789`

## 🔗 Dependencies

### Runtime
| Dependency | Purpose | Required |
|------------|---------|:---:|
| [OpenClaw](https://github.com/openclaw/openclaw) | AI agent gateway (WebSocket backend) | **Yes** |
| Node.js 18+ | Runtime for OpenClaw | **Yes** |
| macOS Premium TTS voices | High-quality speech synthesis | Recommended |

### Build (Swift Package Manager, auto-resolved)
| Package | Purpose |
|---------|---------|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | On-device speech recognition for Apple Silicon |
| [RealTimeCutVADLibrary](https://github.com/sakits/RealTimeCutVADLibrary) | Silero VAD v5 for voice activity detection |

### ML Models (manual download)
| Model | Size | Purpose |
|-------|------|---------|
| `openai_whisper-large-v3` | ~3 GB | Main speech transcription (highest accuracy) |
| `openai_whisper-small` | ~500 MB | Wake word detection (lightweight) |

> The app auto-falls back through `large-v3 → small → base → tiny` for transcription, and `small → base → tiny` for wake word detection. Only models you've downloaded will be used.

## 🤝 Credits

- [OpenClaw](https://github.com/openclaw/openclaw) — AI agent framework
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — On-device speech recognition for Apple Silicon
- [RealTimeCutVADLibrary](https://github.com/sakits/RealTimeCutVADLibrary) — Silero VAD v5 for voice activity detection
- Built with ❤️ by a lobster girl 🦞

## 📄 License

MIT
