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

    private var polishEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "polishEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "polishEnabled") }
    }

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

        let recordItem = NSMenuItem(
            title: isListening ? "⏹  Stop & Paste" : "⏺  Start Recording",
            action: #selector(toggleFromMenu),
            keyEquivalent: "r"
        )
        recordItem.target = self
        recordItem.isEnabled = server.isConnected
        menu.addItem(recordItem)

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

        let polisher = TextPolisher.shared
        let available = polisher.availableProviders
        let configured = !available.isEmpty

        let polishItem = NSMenuItem(
            title: configured ? "✨  Polish (\(polisher.provider.displayName))" : "✨  Polish (no API key)",
            action: #selector(togglePolish),
            keyEquivalent: "p"
        )
        polishItem.target = self
        polishItem.state = (polishEnabled && configured) ? .on : .off
        polishItem.isEnabled = configured
        menu.addItem(polishItem)

        if configured {
            let polishMenu = NSMenu()
            for p in available {
                let item = NSMenuItem(title: p.displayName, action: #selector(setProvider(_:)), keyEquivalent: "")
                item.representedObject = p.rawValue
                item.state = polisher.provider == p ? .on : .off
                item.target = self
                polishMenu.addItem(item)
            }
            polishMenu.addItem(.separator())
            let vocabItem = NSMenuItem(title: "Edit Vocabulary…", action: #selector(editVocabulary), keyEquivalent: "")
            vocabItem.target = self
            polishMenu.addItem(vocabItem)

            let polishSub = NSMenuItem(title: "Polish Settings", action: nil, keyEquivalent: "")
            polishSub.submenu = polishMenu
            menu.addItem(polishSub)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func togglePolish() {
        polishEnabled.toggle()
        Log.write("polish toggled → \(polishEnabled)")
        updateMenu()
    }

    @objc private func setProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let p = TextPolisher.Provider(rawValue: raw) else { return }
        TextPolisher.shared.provider = p
        Log.write("polish provider → \(p.displayName)")
        updateMenu()
    }

    @objc private func editVocabulary() {
        let url = TextPolisher.vocabularyURL
        if !FileManager.default.fileExists(atPath: url.path) {
            // Touch it so the polisher writes its default, then open that.
            _ = TextPolisher.shared.isConfigured()
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleFromMenu() {
        Log.write("menu record item clicked")
        toggleListening()
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
            let text = accumulatedText
            accumulatedText = ""
            isListening = false
            Log.write("ended → '\(text)'")

            guard !text.isEmpty else {
                statusItem.button?.title = "🎙"
                updateMenu()
                return
            }

            if polishEnabled && TextPolisher.shared.isConfigured() {
                statusItem.button?.title = "✨"
                updateMenu()
                TextPolisher.shared.polish(text) { [weak self] result in
                    DispatchQueue.main.async {
                        CursorPaster.paste(result)
                        self?.statusItem.button?.title = "🎙"
                        self?.updateMenu()
                    }
                }
            } else {
                CursorPaster.paste(text)
                statusItem.button?.title = "🎙"
                updateMenu()
            }
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
        fnMonitor.onToggle = { [weak self] in self?.toggleListening() }
        fnMonitor.start()
    }

    private func toggleListening() {
        Log.write("Fn tapped, isListening=\(isListening), connected=\(server.isConnected)")
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
