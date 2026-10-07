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
4. Grant **both** permissions in System Settings → Privacy & Security:
   - **Accessibility** — lets the app post the paste keystroke
   - **Input Monitoring** — lets it observe the Fn key

   These are separate services. With only Accessibility the app pastes fine but
   the hotkey never fires, because macOS disables the event tap within seconds.
5. Put cursor anywhere, press **Fn**, speak, press **Fn** → text pastes

Change language from the menu bar: 🎙 → Language → Thai / English / Japanese / Chinese / Korean.
The menu also has a Start/Stop item, which works while Secure Input is held (any
password field) and no event tap can fire.

## Polish (optional)

A second pass sends the raw transcript to an LLM to fix mis-heard words, drop
filler, and add the spacing Thai speech-to-text omits. Off by default; toggle
with `⌘P` or 🎙 → ✨ Polish.

Most of the value is in the vocabulary file at `~/.config/chromestt/vocabulary.txt`
— terms you say often that STT mangles. Without it, "อาเอสไอ" becomes "AIS", the
telecom; with it, "RSI". Edits apply on the next utterance, no restart.

API keys are read from the Keychain at runtime, never stored in the repo:

```bash
security add-generic-password -U -s "ChromeSTT/DEEPSEEK_API_KEY" -a ChromeSTT -w "YOUR_KEY"
security add-generic-password -U -s "ChromeSTT/GEMINI_API_KEY"   -a ChromeSTT -w "YOUR_KEY"
```

Pick a provider under 🎙 → Polish Settings. On Thai trading jargon DeepSeek ran
faster (~0.6-1.0s vs ~1.0-1.5s) and transliterated better. Calls are bounded at
5s and fall back to the raw transcript on timeout, error, or a result that lost
more than half the input — a slightly rough paste beats one that never lands.

## Trade-offs

- One Chrome tab must stay open.
- Audio goes to Google's servers (same path as voice search).
- With Polish on, the transcript also goes to DeepSeek or Google, and pasting is
  ~0.6-1.5s slower. Turn it off for anything sensitive.
