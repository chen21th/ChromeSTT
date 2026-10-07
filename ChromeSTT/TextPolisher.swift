import Foundation
import Security

/// Second pass over a raw transcript: the LLM repairs mis-heard words, drops
/// filler and stutters, and adds the spacing Thai speech-to-text omits.
///
/// The domain vocabulary carries most of the value. Without it "อาเอสไอ" becomes
/// "AIS", the telecom; with it, "RSI". Users edit their own list via the menu.
///
/// Latency is uneven — roughly 0.6-1.5s typically, with multi-second tails and
/// occasional 503s — so every call is bounded and falls back to the raw text.
/// A slightly rough paste beats a paste that never lands.
final class TextPolisher {
    static let shared = TextPolisher()

    enum Provider: String, CaseIterable {
        case deepseek, gemini

        var displayName: String {
            switch self {
            case .deepseek: return "DeepSeek"
            case .gemini:   return "Gemini"
            }
        }

        var keychainServices: [String] {
            switch self {
            case .deepseek: return ["ChromeSTT/DEEPSEEK_API_KEY"]
            case .gemini:   return ["ChromeSTT/GEMINI_API_KEY", "CallyASMRVideo/GEMINI_API_KEY"]
            }
        }
    }

    private let timeout: TimeInterval = 5.0

    /// Reused so TLS and HTTP/2 connections stay warm between utterances.
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeout
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    var provider: Provider {
        get { Provider(rawValue: UserDefaults.standard.string(forKey: "polishProvider") ?? "") ?? .deepseek }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "polishProvider") }
    }

    func isConfigured(_ p: Provider? = nil) -> Bool { apiKey(for: p ?? provider) != nil }

    var availableProviders: [Provider] { Provider.allCases.filter { apiKey(for: $0) != nil } }

    // MARK: - Vocabulary

    static let vocabularyURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/chromestt", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vocabulary.txt")
    }()

    private static let defaultVocabulary = """
    # ChromeSTT — domain vocabulary
    #
    # Terms you say often that speech-to-text tends to mangle. The model uses
    # this to pick the word you meant. Lines starting with # are ignored.
    # Edit freely, then dictate again — no restart needed.

    RSI, MACD, EMA, SMA, ADX, ATR, Bollinger Bands, Fibonacci, Stochastic, Ichimoku
    breakout, divergence, timeframe, volume, candlestick, overbought, oversold
    support/resistance (แนวรับ/แนวต้าน), order block, liquidity, backtest
    stop loss, take profit, drawdown, sideway, swing, scalping, long/short
    """

    /// Read fresh each call so edits take effect without relaunching.
    private var vocabulary: String {
        if let text = try? String(contentsOf: Self.vocabularyURL, encoding: .utf8) {
            let terms = text
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                .joined(separator: "\n")
            if !terms.isEmpty { return terms }
        }
        try? Self.defaultVocabulary.write(to: Self.vocabularyURL, atomically: true, encoding: .utf8)
        return Self.defaultVocabulary
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .joined(separator: "\n")
    }

    /// Teaching the model *how* Thai mangles English loanwords generalises far
    /// better than listing terms. With only a glossary, "เอ็นพอยท์" and
    /// "อะซิงโครนัส" survive as Thai; explain the phonetic mapping and the same
    /// model returns "endpoint" and "asynchronous" without either being listed.
    private func buildPrompt(for raw: String) -> String {
        """
        คุณกำลังจัดข้อความจากการถอดเสียงพูดของคนไทยที่ทำงานสายเทคนิค

        สิ่งสำคัญที่ต้องเข้าใจ: คนไทยออกเสียงศัพท์อังกฤษผ่านระบบเสียงภาษาไทย ซึ่งไม่มีตัวสะกดควบท้ายและไม่มีเสียงบางเสียง ระบบถอดเสียงจึงเขียนออกมาเป็นคำไทยที่ดูไม่มีความหมาย ให้คุณถอดกลับเป็นศัพท์อังกฤษที่ผู้พูดตั้งใจ

        รูปแบบการเพี้ยนที่พบบ่อย:
        - ตัวสะกดท้ายเปลี่ยนหรือหาย: commit→คอมมิส, GitHub→กิตหับ, cache→แคช, object→อ็อบเจ็ก
        - เสียงควบกล้ำถูกแยกหรือตัด: script→สคริป, class→คลาส, string→สตริง
        - r/l สลับกัน, v→ว, th→ท, z→ส
        - เติมสระให้ออกเสียงง่าย: query→เควอรี่, library→ไลบรารี่

        วิธีคิด: ถ้าเจอคำไทยที่อ่านแล้วไม่เป็นภาษาไทยปกติ และอยู่ในบริบทเทคนิค ให้ลองออกเสียงดูว่าใกล้เคียงศัพท์อังกฤษคำไหน แล้วใช้คำนั้น ถึงแม้จะไม่อยู่ในรายการข้างล่างก็ตาม

        ศัพท์ที่ผู้พูดใช้บ่อย (ใช้เป็นเบาะแสบริบท ไม่ใช่ขอบเขตจำกัด):
        \(vocabulary)

        ทำ:
        - ใส่เว้นวรรคระหว่างวลี และเครื่องหมายวรรคตอน
        - ตัดคำติดปาก (เออ, อ่า, แบบว่า, คือว่า) และคำที่พูดซ้ำติดกันโดยไม่ตั้งใจ
        - แปลงศัพท์เทคนิคที่เพี้ยนกลับเป็นคำอังกฤษที่ถูกต้อง

        ห้าม:
        - เพิ่มใจความ ความคิด หรือคำที่ผู้พูดไม่ได้พูด
        - ตัดใจความใดออก แม้จะดูไม่สำคัญ
        - เปลี่ยนระดับภาษา คำหยาบ หรือคำสแลงให้เป็นทางการ
        - แปลงคำไทยแท้ที่ไม่ใช่ศัพท์เทคนิคเป็นอังกฤษ

        ตอบเฉพาะข้อความผลลัพธ์

        ข้อความ: \(raw)
        """
    }

    // MARK: - Polish

    /// Calls back with the polished text, or `raw` unchanged if the provider is
    /// unconfigured, too slow, or returns something suspect.
    func polish(_ raw: String, completion: @escaping (String) -> Void) {
        let p = provider
        guard let key = apiKey(for: p) else {
            Log.write("polish: no \(p.displayName) key in Keychain, pasting raw")
            completion(raw)
            return
        }

        guard let request = makeRequest(provider: p, key: key, prompt: buildPrompt(for: raw)) else {
            completion(raw)
            return
        }

        let started = Date()
        session.dataTask(with: request) { data, response, error in
            let elapsed = Date().timeIntervalSince(started)
            let stamp = String(format: "%.2f", elapsed)

            if let error {
                Log.write("polish: \(p.displayName) failed after \(stamp)s — \(error.localizedDescription)")
                completion(raw)
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                Log.write("polish: \(p.displayName) HTTP \(http.statusCode) after \(stamp)s")
                completion(raw)
                return
            }
            guard let data, let text = Self.extractText(provider: p, data: data) else {
                Log.write("polish: \(p.displayName) unexpected response, pasting raw")
                completion(raw)
                return
            }

            let polished = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // A result far shorter than the input means content was dropped;
            // the raw transcript is the safer paste.
            guard !polished.isEmpty, polished.count >= raw.count / 2 else {
                Log.write("polish: result looks truncated (\(polished.count) vs \(raw.count)), pasting raw")
                completion(raw)
                return
            }

            Log.write("polish: \(p.displayName) ok in \(stamp)s")
            completion(polished)
        }.resume()
    }

    private func makeRequest(provider p: Provider, key: String, prompt: String) -> URLRequest? {
        let url: URL
        var payload: [String: Any]
        var headers: [String: String] = ["Content-Type": "application/json"]

        switch p {
        case .deepseek:
            url = URL(string: "https://api.deepseek.com/chat/completions")!
            headers["Authorization"] = "Bearer \(key)"
            payload = [
                "model": "deepseek-chat",
                "temperature": 0.1,
                "messages": [["role": "user", "content": prompt]],
            ]
        case .gemini:
            url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent?key=\(key)")!
            payload = [
                "contents": [["parts": [["text": prompt]]]],
                "generationConfig": ["temperature": 0.1],
            ]
        }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        return req
    }

    private static func extractText(provider p: Provider, data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch p {
        case .deepseek:
            let choices = json["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            return message?["content"] as? String
        case .gemini:
            let candidates = json["candidates"] as? [[String: Any]]
            let content = candidates?.first?["content"] as? [String: Any]
            let parts = content?["parts"] as? [[String: Any]]
            return parts?.first?["text"] as? String
        }
    }

    // MARK: - Keychain

    private func apiKey(for p: Provider) -> String? {
        for service in p.keychainServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
               let data = item as? Data,
               let key = String(data: data, encoding: .utf8) {
                return key.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}
