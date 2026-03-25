import Foundation

/// Lightweight HTTP server that receives reply requests and sends them via AppleScript
class ReplyServer {
    let port: UInt16
    
    init(port: UInt16) {
        self.port = port
    }
    
    func start() {
        let socket = socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else {
            Logger.shared.log("❌ Failed to create socket")
            return
        }
        
        var yes: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(socket, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        guard bindResult == 0 else {
            Logger.shared.log("❌ Failed to bind port \(port): \(String(cString: strerror(errno)))")
            close(socket)
            return
        }
        
        listen(socket, 5)
        Logger.shared.log("🌐 Reply server listening on port \(port)")
        
        while true {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            
            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(socket, sockPtr, &clientLen)
                }
            }
            
            guard clientSocket >= 0 else { continue }
            
            DispatchQueue.global().async { [self] in
                self.handleClient(clientSocket)
            }
        }
    }
    
    private func handleClient(_ socket: Int32) {
        defer { close(socket) }
        
        // Read request
        var buffer = [UInt8](repeating: 0, count: 65536)
        let bytesRead = read(socket, &buffer, buffer.count)
        guard bytesRead > 0 else { return }
        
        let requestStr = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
        
        // Parse HTTP request
        let lines = requestStr.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0])
        let path = String(parts[1])
        
        // Health check
        if method == "GET" && path == "/health" {
            let response = httpResponse(status: 200, body: #"{"status":"ok","service":"JerbotRelay"}"#)
            send(socket, response, response.count, 0)
            return
        }
        
        // Send reply endpoint
        if method == "POST" && path == "/send" {
            // Extract body (after \r\n\r\n)
            guard let bodyRange = requestStr.range(of: "\r\n\r\n") else {
                let response = httpResponse(status: 400, body: #"{"error":"no body"}"#)
                send(socket, response, response.count, 0)
                return
            }
            
            let bodyStr = String(requestStr[bodyRange.upperBound...])
            
            guard let bodyData = bodyStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                  let chatIdentifier = json["chat_identifier"] as? String,
                  let text = json["text"] as? String else {
                let response = httpResponse(status: 400, body: #"{"error":"need chat_identifier and text"}"#)
                send(socket, response, response.count, 0)
                return
            }
            
            Logger.shared.log("📤 Sending reply to \(chatIdentifier): \(text.prefix(80))")
            
            let success = sendViaAppleScript(to: chatIdentifier, text: text)
            
            if success {
                let response = httpResponse(status: 200, body: #"{"status":"sent"}"#)
                send(socket, response, response.count, 0)
                Logger.shared.log("✅ Reply sent successfully")
            } else {
                let response = httpResponse(status: 500, body: #"{"error":"AppleScript send failed"}"#)
                send(socket, response, response.count, 0)
                Logger.shared.log("❌ Reply send failed")
            }
            return
        }
        
        // 404
        let response = httpResponse(status: 404, body: #"{"error":"not found","endpoints":["GET /health","POST /send"]}"#)
        send(socket, response, response.count, 0)
    }
    
    private func sendViaAppleScript(to chatIdentifier: String, text: String) -> Bool {
        // Escape text for AppleScript
        let escapedText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        
        let escapedChat = chatIdentifier
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        
        // Determine service (iMessage vs SMS based on chat identifier)
        let service = chatIdentifier.contains("+") || chatIdentifier.allSatisfy({ $0.isNumber || $0 == "+" })
            ? "SMS" : "iMessage"
        
        let script: String
        if chatIdentifier.hasPrefix("chat") {
            // Group chat — use chat identifier directly
            script = """
            tell application "Messages"
                set targetChat to a reference to chat id "\(escapedChat)"
                send "\(escapedText)" to targetChat
            end tell
            """
        } else {
            // Direct message — use buddy
            script = """
            tell application "Messages"
                set targetService to 1st service whose service type = \(service)
                set targetBuddy to buddy "\(escapedChat)" of targetService
                send "\(escapedText)" to targetBuddy
            end tell
            """
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        
        let pipe = Pipe()
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus != 0 {
                let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errorStr = String(data: errorData, encoding: .utf8) ?? "unknown error"
                Logger.shared.log("❌ AppleScript error: \(errorStr)")
                return false
            }
            return true
        } catch {
            Logger.shared.log("❌ Process error: \(error.localizedDescription)")
            return false
        }
    }
    
    private func httpResponse(status: Int, body: String) -> String {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }
        
        return """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        Access-Control-Allow-Origin: *\r
        \r
        \(body)
        """
    }
}
