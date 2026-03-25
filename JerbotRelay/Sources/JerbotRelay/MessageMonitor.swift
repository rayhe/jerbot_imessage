import Foundation
import SQLite3

/// Monitors ~/Library/Messages/chat.db for new messages and forwards them to a webhook
class MessageMonitor {
    let config: Config
    private var lastRowID: Int64 = 0
    private let dbPath: String
    
    init(config: Config) {
        self.config = config
        self.dbPath = NSHomeDirectory() + "/Library/Messages/chat.db"
        self.lastRowID = getMaxRowID() ?? 0
        Logger.shared.log("📨 Starting from message ROWID: \(lastRowID)")
    }
    
    func startPolling() {
        Logger.shared.log("🔄 Polling chat.db every \(config.pollIntervalSeconds)s")
        while true {
            checkForNewMessages()
            Thread.sleep(forTimeInterval: config.pollIntervalSeconds)
        }
    }
    
    private func getMaxRowID() -> Int64? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            Logger.shared.log("❌ Cannot open chat.db — do you have Full Disk Access enabled?")
            return nil
        }
        defer { sqlite3_close(db) }
        
        var stmt: OpaquePointer?
        let sql = "SELECT MAX(ROWID) FROM message"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int64(stmt, 0)
        }
        return nil
    }
    
    private func checkForNewMessages() {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            Logger.shared.log("❌ Cannot open chat.db")
            return
        }
        defer { sqlite3_close(db) }
        
        let sql = """
            SELECT
                m.ROWID,
                m.text,
                m.date,
                m.is_from_me,
                m.service,
                h.id AS sender_id,
                h.uncanonicalized_id AS sender_display,
                c.chat_identifier,
                c.display_name AS chat_name,
                c.style AS chat_style
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN chat c ON cmj.chat_id = c.ROWID
            WHERE m.ROWID > ?
            ORDER BY m.ROWID ASC
            LIMIT 50
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Logger.shared.log("❌ SQL prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_int64(stmt, 1, lastRowID)
        
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = sqlite3_column_int64(stmt, 0)
            let text = columnText(stmt, 1) ?? ""
            let dateVal = sqlite3_column_int64(stmt, 2)
            let isFromMe = sqlite3_column_int(stmt, 3) == 1
            let service = columnText(stmt, 4) ?? "iMessage"
            let senderID = columnText(stmt, 5) ?? "unknown"
            let senderDisplay = columnText(stmt, 6) ?? senderID
            let chatIdentifier = columnText(stmt, 7) ?? "unknown"
            let chatName = columnText(stmt, 8)
            let chatStyle = sqlite3_column_int(stmt, 9)
            
            // Skip our own outgoing messages
            if isFromMe { 
                lastRowID = rowid
                continue 
            }
            
            // Skip empty messages (tapbacks, read receipts, etc)
            if text.isEmpty {
                lastRowID = rowid
                continue
            }
            
            // Convert Apple's CoreData timestamp (nanoseconds since 2001-01-01) to Unix
            let appleEpoch = Date(timeIntervalSinceReferenceDate: 0) // 2001-01-01
            let timestamp = appleEpoch.timeIntervalSince1970 + Double(dateVal) / 1_000_000_000.0
            
            let isGroup = chatStyle == 43 // 43 = group chat, 45 = DM
            
            // Check for attachments
            let attachments = getAttachments(db: db!, messageRowID: rowid)
            
            let payload: [String: Any] = [
                "rowid": rowid,
                "text": text,
                "timestamp": timestamp,
                "sender_id": senderID,
                "sender_display": senderDisplay,
                "chat_identifier": chatIdentifier,
                "chat_name": chatName ?? NSNull(),
                "is_group": isGroup,
                "service": service,
                "attachments": attachments
            ]
            
            Logger.shared.log("📩 New message from \(senderDisplay) in \(chatName ?? chatIdentifier): \(text.prefix(80))")
            forwardToWebhook(payload: payload)
            
            lastRowID = rowid
        }
    }
    
    private func getAttachments(db: OpaquePointer, messageRowID: Int64) -> [[String: Any]] {
        let sql = """
            SELECT a.filename, a.mime_type, a.total_bytes
            FROM attachment a
            JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
            WHERE maj.message_id = ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_int64(stmt, 1, messageRowID)
        
        var results: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let filename = columnText(stmt, 0) ?? ""
            let mimeType = columnText(stmt, 1) ?? "application/octet-stream"
            let totalBytes = sqlite3_column_int64(stmt, 2)
            results.append([
                "filename": filename,
                "mime_type": mimeType,
                "total_bytes": totalBytes
            ])
        }
        return results
    }
    
    private func forwardToWebhook(payload: [String: Any]) {
        guard let url = URL(string: config.webhookURL) else {
            Logger.shared.log("❌ Invalid webhook URL: \(config.webhookURL)")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("JerbotRelay/1.0", forHTTPHeaderField: "User-Agent")
        
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            Logger.shared.log("❌ Failed to serialize payload")
            return
        }
        request.httpBody = body
        
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                Logger.shared.log("❌ Webhook error: \(error.localizedDescription)")
            } else if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 {
                    Logger.shared.log("✅ Webhook delivered (HTTP \(httpResponse.statusCode))")
                } else {
                    Logger.shared.log("⚠️  Webhook returned HTTP \(httpResponse.statusCode)")
                }
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 10)
    }
    
    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }
}
