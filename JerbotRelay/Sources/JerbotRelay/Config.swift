import Foundation

/// Configuration loaded from ~/.jerbot_relay.json or defaults
struct Config: Codable {
    let webhookURL: String
    let pollIntervalSeconds: Double
    let replyPort: UInt16
    let logFile: String
    
    static let configPath = NSHomeDirectory() + "/.jerbot_relay.json"
    
    static let defaults = Config(
        webhookURL: "http://localhost:3000/webhook/imessage",
        pollIntervalSeconds: 2.0,
        replyPort: 8765,
        logFile: NSHomeDirectory() + "/Library/Logs/JerbotRelay.log"
    )
    
    static func load() -> Config {
        let path = configPath
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let config = try? JSONDecoder().decode(Config.self, from: data) else {
            Logger.shared.log("⚠️  No config at \(path), using defaults")
            Logger.shared.log("   Create config: cp config.example.json ~/.jerbot_relay.json")
            return defaults
        }
        Logger.shared.log("📋 Loaded config from \(path)")
        return config
    }
}
