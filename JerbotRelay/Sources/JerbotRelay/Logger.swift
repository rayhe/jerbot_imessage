import Foundation

/// Simple file + stdout logger
class Logger {
    static let shared = Logger()
    private var logFileHandle: FileHandle?
    
    private init() {
        let logPath = Config.defaults.logFile
        let dir = (logPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        logFileHandle = FileHandle(forWritingAtPath: logPath)
        logFileHandle?.seekToEndOfFile()
    }
    
    func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        print(line, terminator: "")
        if let data = line.data(using: .utf8) {
            logFileHandle?.write(data)
        }
    }
}
