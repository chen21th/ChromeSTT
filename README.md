# ChromeSTT

Free, high-quality Thai (+ multilingual) speech-to-text for macOS — powered by Chrome's Web Speech API (Google STT). No API key, no cost.

## How it works

1. ChromeSTT runs a tiny local WebSocket server (port 9876) + serves an HTML page
2. You keep one Chrome tab open at `http://127.0.0.1:9876`
3. The page uses `webkitSpeechRecognition` — Chrome streams your mic to Google and returns transcripts (free)
4. Press **Fn** → ChromeSTT tells the tab to start listening → press **Fn** again → stops → text is pasted at your cursor

## Build

```bash
swift build -c release
```

Binary: `.build/release/ChromeSTT`

## Package as .app

```bash
APP=~/Desktop/ChromeSTT.app
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ChromeSTT "$APP/Contents/MacOS/"
# Then write Info.plist (see repo's build script)
```

## Usage

1. Launch `ChromeSTT.app` (menu bar icon 🎙 appears)
2. Open Chrome at `http://127.0.0.1:9876`
3. Allow microphone access when Chrome asks
4. Grant Accessibility permission to ChromeSTT (System Settings → Privacy & Security → Accessibility) so it can detect the Fn key and paste
5. Put cursor anywhere, press **Fn**, speak, press **Fn** → text pastes

Change language from the menu bar: 🎙 → Language → Thai / English / Japanese / Chinese / Korean

## Why

Replaces paid cloud STT APIs (Deepgram, Whisper API, etc.) for personal dictation. Trade-off: must keep Chrome tab open; audio goes through Google's servers.
