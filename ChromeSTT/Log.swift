import Foundation

enum Log {
    static let path = "/tmp/chromestt.log"
    private static let queue = DispatchQueue(label: "chromestt.log")

    static func write(_ msg: String) {
        queue.async {
            let line = "[\(Date())] \(msg)\n"
            guard let data = line.data(using: .utf8) else { return }
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            }
        }
    }
}
