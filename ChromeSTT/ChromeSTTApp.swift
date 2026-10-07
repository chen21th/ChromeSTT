import AppKit

@main
struct ChromeSTTApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let server = WebSocketServer()
    private let fnMonitor = FnKeyMonitor()
    private var isListening = false
    private var language = "th-TH"
    private var accumulatedText = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        setupServer()
        setupHotKey()
        openChromeTab()
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙"
        updateMenu()
    }

    private func updateMenu() {
        let menu = NSMenu()
        let statusTitle = isListening ? "⏺ Listening..." : (server.isConnected ? "✅ Chrome Connected" : "⏳ Waiting for Chrome...")
        menu.addItem(NSMenuItem(title: statusTitle, action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Chrome Tab", action: #selector(openChromeTab), keyEquivalent: "o"))

        let langMenu = NSMenu()
        for (code, name) in [("th-TH", "Thai"), ("en-US", "English"), ("ja-JP", "Japanese"), ("zh-CN", "Chinese"), ("ko-KR", "Korean")] {
            let item = NSMenuItem(title: name, action: #selector(setLanguage(_:)), keyEquivalent: "")
            item.representedObject = code
            item.state = language == code ? .on : .off
            item.target = self
            langMenu.addItem(item)
        }
        let langItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        langItem.submenu = langMenu
        menu.addItem(langItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String {
            language = code
            updateMenu()
        }
    }

    private func setupServer() {
        server.onTranscript = { [weak self] event in
            self?.handleTranscript(event)
        }
        server.onConnectionChanged = { [weak self] connected in
            Log.write("Chrome \(connected ? "CONNECTED" : "DISCONNECTED")")
            self?.updateMenu()
        }
        do {
            try server.start()
        } catch {
            print("Failed to start server: \(error)")
        }
    }

    private func handleTranscript(_ event: TranscriptEvent) {
        Log.write("transcript kind=\(event.kind) text='\(event.text)'")
        switch event.kind {
        case .final:
            accumulatedText = event.text
        case .ended:
            Log.write("ended → paste='\(accumulatedText)'")
            if !accumulatedText.isEmpty {
                CursorPaster.paste(accumulatedText)
                accumulatedText = ""
            }
            isListening = false
            statusItem.button?.title = "🎙"
            updateMenu()
        case .partial:
            break
        case .error:
            Log.write("STT error: \(event.text)")
            isListening = false
            statusItem.button?.title = "🎙"
            updateMenu()
        }
    }

    private func setupHotKey() {
        fnMonitor.onToggle = { [weak self] in
            self?.toggleListening()
        }
        fnMonitor.start()
    }

    private func toggleListening() {
        Log.write("hotkey pressed, isListening=\(isListening), connected=\(server.isConnected)")
        if isListening {
            server.sendStop()
            isListening = false
            statusItem.button?.title = "🎙"
        } else {
            guard server.isConnected else {
                Log.write("not connected, opening Chrome tab")
                openChromeTab()
                return
            }
            accumulatedText = ""
            server.sendStart(lang: language)
            isListening = true
            statusItem.button?.title = "⏺"
        }
        updateMenu()
    }

    @objc private func openChromeTab() {
        let url = URL(string: "http://127.0.0.1:\(server.port)")!
        NSWorkspace.shared.open(url)
    }
}
