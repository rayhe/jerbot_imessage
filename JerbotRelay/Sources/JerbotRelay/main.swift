import Foundation
import AppKit

/// JerbotRelay — macOS iMessage relay for bot webhooks
/// Monitors ~/Library/Messages/chat.db, forwards new messages to a webhook,
/// listens for replies on a local HTTP server, sends them back via AppleScript.

@main
struct JerbotRelayApp {
    static func main() {
        let config = Config.load()
        
        Logger.shared.log("🤖 JerbotRelay starting...")
        Logger.shared.log("   Webhook: \(config.webhookURL)")
        Logger.shared.log("   Poll interval: \(config.pollIntervalSeconds)s")
        Logger.shared.log("   Reply server port: \(config.replyPort)")
        
        let monitor = MessageMonitor(config: config)
        let replyServer = ReplyServer(port: config.replyPort)
        
        // Start monitoring in background
        DispatchQueue.global(qos: .userInitiated).async {
            monitor.startPolling()
        }
        
        // Start reply server in background
        DispatchQueue.global(qos: .userInitiated).async {
            replyServer.start()
        }
        
        // Set up as menu bar app
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory) // No dock icon
        
        let statusBar = NSStatusBar.system
        let statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "💬"
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "JerbotRelay Running", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        
        let webhookItem = NSMenuItem(title: "Webhook: \(config.webhookURL)", action: nil, keyEquivalent: "")
        webhookItem.isEnabled = false
        menu.addItem(webhookItem)
        
        let portItem = NSMenuItem(title: "Reply Port: \(config.replyPort)", action: nil, keyEquivalent: "")
        portItem.isEnabled = false
        menu.addItem(portItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem.menu = menu
        
        Logger.shared.log("✅ JerbotRelay ready. Menu bar icon active.")
        app.run()
    }
}
