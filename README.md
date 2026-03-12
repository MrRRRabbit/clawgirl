# 🦞 Clawgirl

A native macOS desktop companion for [OpenClaw](https://github.com/openclaw/openclaw) AI agents — with voice wake word detection, real-time chat, and text-to-speech.

> Talk to your AI agent like talking to a friend. Say the wake word, speak naturally, and hear the response read back to you.

## ✨ Features

- **🎤 Voice Wake Word Detection** — Say "小虾" (or any custom wake word) to activate hands-free voice input
- **🗣️ Speech-to-Text** — Powered by [WhisperKit](https://github.com/argmaxinc/WhisperKit) (on-device, no cloud API needed)
- **🔊 Text-to-Speech** — Hear AI responses read aloud with configurable macOS voices
- **💬 Real-time Chat** — WebSocket connection to your OpenClaw gateway with streaming responses
- **🖼️ Image Support** — Drag & drop or paste images to send with your messages
- **🌊 Beautiful UI** — Ocean blue theme with state-aware animations (idle ripple, listening waves, thinking dots, speaking bars)
- **⚙️ Fully Configurable** — Gateway URL, token, session, wake words, model path — all in the settings panel

## 📋 Requirements

- **macOS 14.0+** (Sonoma or later)
- **Apple Silicon** (M1/M2/M3/M4) — required for WhisperKit CoreML models
- **Xcode 16+** — to build the project
- **[OpenClaw](https://github.com/openclaw/openclaw)** — running gateway on your machine or network

## 🚀 Quick Start

### 1. Clone the repo

```bash
git clone https://github.com/MrRRRabbit/clawgirl.git
cd clawgirl
```

### 2. Download WhisperKit models

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

### 3. Build & Run

Open `Clawgirl.xcodeproj` in Xcode, then:

1. Wait for Swift Package Manager to resolve WhisperKit dependency
2. Select your Mac as the run destination
3. Press `⌘R` to build and run

### 4. Configure

Click the ⚙️ gear icon in the app to configure:

| Setting | Description | Default |
|---------|-------------|---------|
| **Gateway URL** | Your OpenClaw gateway WebSocket address | `ws://127.0.0.1:18789` |
| **Gateway Token** | Authentication token from `~/.openclaw/openclaw.json` | Auto-detected |
| **Session Key** | Which OpenClaw session to connect to | `main` |
| **Model Path** | Where WhisperKit CoreML models are stored | `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml` |
| **Wake Words** | Words that trigger voice input | 小虾, 小蝦, 小夏, ... |

> **Note:** The gateway token is automatically loaded from your local OpenClaw config on first launch. You only need to set it manually if you're connecting to a remote gateway.

## 🎙️ How Voice Wake Works

```
┌─────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────┐
│  Always-on   │     │  🔔 Alert    │     │  🎤 Record   │     │  📤 Send │
│  Listening   │────▶│  Sound       │────▶│  Your Voice  │────▶│  Message │
│  (small model)│     │  (Glass.aiff)│     │  (large-v3)  │     │          │
└─────────────┘     └──────────────┘     └──────────────┘     └──────────┘
       │                                        │                    │
       │ Say "小虾"                    VAD auto-stop           🔔 Submarine
       │                              (3.5s silence)           sound plays
       ▼                                        ▼                    ▼
  WhisperKit small                      WhisperKit large-v3    AI responds
  (wake word only,                     (full transcription)    with TTS
   never sent)
```

1. **Idle** — WhisperKit `small` model continuously listens for the wake word (low CPU usage)
2. **Wake** — Wake word detected → plays Glass alert sound → waits 500ms
3. **Record** — Records your speech until 3.5 seconds of silence (VAD auto-stop)
4. **Send** — Transcribes with WhisperKit `large-v3` → plays Submarine sound → sends to OpenClaw
5. **Reply** — AI response streams in → displayed in chat → read aloud via TTS
6. **Resume** — Returns to wake word listening

## ⌨️ Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘D` | Push-to-talk (hold to record, release to send) |
| `Enter` | Send text message |
| `⌘V` | Paste image from clipboard |

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
│   ├── ChatManager.swift           # Core logic: chat, TTS, WebSocket, WhisperKit
│   ├── WakeWordDetector.swift      # Wake word detection with WhisperKit small
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

### Wake word not detecting
- Check that the 👂 ear icon is active (turquoise)
- Check the ⚙️ settings panel — wake model status should be 🟢
- Try speaking louder or closer to the microphone
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

## 🤝 Credits

- [OpenClaw](https://github.com/openclaw/openclaw) — AI agent framework
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — On-device speech recognition for Apple Silicon
- Built with ❤️ by a lobster girl 🦞

## 📄 License

MIT
