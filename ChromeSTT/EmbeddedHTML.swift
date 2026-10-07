enum EmbeddedHTML {
    static let sttHTML = #"""
<!DOCTYPE html>
<html lang="th">
<head>
<meta charset="UTF-8">
<title>ChromeSTT</title>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: -apple-system, system-ui, sans-serif;
    background: #1a1a1a; color: #e0e0e0;
    display: flex; flex-direction: column;
    align-items: center; justify-content: center;
    height: 100vh; gap: 20px;
  }
  #status {
    font-size: 14px; color: #888;
    display: flex; align-items: center; gap: 8px;
  }
  #dot {
    width: 10px; height: 10px; border-radius: 50%;
    background: #555; transition: background 0.3s;
  }
  #dot.connected { background: #4caf50; }
  #dot.listening { background: #f44336; animation: pulse 1s infinite; }
  #transcript {
    font-size: 18px; max-width: 600px; text-align: center;
    min-height: 60px; color: #fff; line-height: 1.6;
  }
  #partial { color: #888; font-style: italic; }
  @keyframes pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.4; }
  }
  .hint { font-size: 12px; color: #555; margin-top: 20px; }
</style>
</head>
<body>
  <div id="status"><div id="dot"></div><span id="statusText">Connecting...</span></div>
  <div id="transcript">
    <div id="final"></div>
    <div id="partial"></div>
  </div>
  <div class="hint">Keep this tab open — ChromeSTT app controls recording via hotkey</div>

<script>
const dot = document.getElementById('dot');
const statusText = document.getElementById('statusText');
const finalEl = document.getElementById('final');
const partialEl = document.getElementById('partial');

let ws = null;
let recognition = null;
let isListening = false;

function connectWS() {
  ws = new WebSocket(`ws://127.0.0.1:${location.port}/ws`);

  ws.onopen = () => {
    dot.className = 'connected';
    statusText.textContent = 'Ready — press hotkey to start';
  };

  ws.onmessage = (e) => {
    const msg = JSON.parse(e.data);
    if (msg.cmd === 'start') startRecognition(msg.lang || 'th-TH');
    else if (msg.cmd === 'stop') stopRecognition();
  };

  ws.onclose = () => {
    dot.className = '';
    statusText.textContent = 'Disconnected — reconnecting...';
    setTimeout(connectWS, 1000);
  };

  ws.onerror = () => ws.close();
}

function startRecognition(lang) {
  if (isListening) return;

  recognition = new webkitSpeechRecognition();
  recognition.continuous = true;
  recognition.interimResults = true;
  recognition.lang = lang;

  recognition.onstart = () => {
    isListening = true;
    dot.className = 'listening';
    statusText.textContent = 'Listening...';
    finalEl.textContent = '';
    partialEl.textContent = '';
  };

  recognition.onresult = (event) => {
    let finalText = '';
    let interimText = '';

    for (let i = 0; i < event.results.length; i++) {
      const result = event.results[i];
      if (result.isFinal) {
        finalText += result[0].transcript;
      } else {
        interimText += result[0].transcript;
      }
    }

    if (finalText) {
      finalEl.textContent = finalText;
      send({ type: 'final', text: finalText });
    }
    if (interimText) {
      partialEl.textContent = interimText;
      send({ type: 'partial', text: interimText });
    }
  };

  recognition.onerror = (event) => {
    if (event.error !== 'aborted') {
      console.error('Recognition error:', event.error);
      send({ type: 'error', error: event.error });
    }
  };

  recognition.onend = () => {
    isListening = false;
    dot.className = 'connected';
    statusText.textContent = 'Ready — press hotkey to start';
    send({ type: 'ended' });
  };

  recognition.start();
}

function stopRecognition() {
  if (recognition && isListening) {
    recognition.stop();
  }
}

function send(obj) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(obj));
  }
}

connectWS();
</script>
</body>
</html>
"""#
}
