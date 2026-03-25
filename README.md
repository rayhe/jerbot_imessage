# JerbotRelay

A lightweight macOS menu bar app that bridges iMessage to any bot via webhooks. Built for [Jerbotclaw](https://github.com/jerbotclaw) as a simpler alternative to BlueBubbles.

**No external dependencies.** Pure Swift + Foundation + AppKit + SQLite3.

## What It Does

```
iMessage → chat.db → JerbotRelay → POST webhook → Your bot
Your bot → POST /send → JerbotRelay → AppleScript → iMessage
```

1. **Monitors** `~/Library/Messages/chat.db` for new incoming messages (polls every 2s)
2. **Forwards** each message as JSON to your configured webhook URL
3. **Listens** on a local HTTP server (default port 8765) for reply commands
4. **Sends replies** back through iMessage via AppleScript
5. **Runs as a menu bar app** — no dock icon, just a 💬 in your menu bar

## Quick Start

### 1. Build

```bash
cd JerbotRelay
swift build -c release
```

The binary lands at `.build/release/JerbotRelay`.

Or open in Xcode:
```bash
open JerbotRelay/Package.swift
```

### 2. Grant Full Disk Access

**Required.** JerbotRelay reads `~/Library/Messages/chat.db` which is protected by macOS.

1. System Settings → Privacy & Security → Full Disk Access
2. Click + and add the `JerbotRelay` binary (or Terminal.app if running from terminal)

Without this, you'll see: `❌ Cannot open chat.db`

### 3. Configure

```bash
cp config.example.json ~/.jerbot_relay.json
```

Edit `~/.jerbot_relay.json`:

```json
{
    "webhookURL": "http://localhost:3000/webhook/imessage",
    "pollIntervalSeconds": 2.0,
    "replyPort": 8765,
    "logFile": "~/Library/Logs/JerbotRelay.log"
}
```

| Field | Description | Default |
|-------|-------------|---------|
| `webhookURL` | Where to POST new messages | `http://localhost:3000/webhook/imessage` |
| `pollIntervalSeconds` | How often to check chat.db | `2.0` |
| `replyPort` | Local HTTP server port for replies | `8765` |
| `logFile` | Log file path | `~/Library/Logs/JerbotRelay.log` |

### 4. Run

```bash
.build/release/JerbotRelay
```

You'll see 💬 in your menu bar. Logs go to stdout and `~/Library/Logs/JerbotRelay.log`.

### 5. Launch at Login (optional)

Create `~/Library/LaunchAgents/com.jerbot.relay.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.jerbot.relay</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/JerbotRelay</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.jerbot.relay.plist
```

## Webhook Payload Format

When a new iMessage arrives, JerbotRelay POSTs JSON to your webhook:

```json
{
    "rowid": 12345,
    "text": "Hey, what's up?",
    "timestamp": 1711324800.0,
    "sender_id": "+14155551234",
    "sender_display": "+14155551234",
    "chat_identifier": "chat123456789",
    "chat_name": "The Squad",
    "is_group": true,
    "service": "iMessage",
    "attachments": [
        {
            "filename": "~/Library/Messages/Attachments/ab/12/IMG_1234.jpeg",
            "mime_type": "image/jpeg",
            "total_bytes": 245760
        }
    ]
}
```

| Field | Type | Description |
|-------|------|-------------|
| `rowid` | int | Unique message ID from chat.db |
| `text` | string | Message text content |
| `timestamp` | float | Unix timestamp |
| `sender_id` | string | Phone number or email of sender |
| `sender_display` | string | Display name if available |
| `chat_identifier` | string | Chat/conversation ID (use this for replies) |
| `chat_name` | string? | Group chat name, null for DMs |
| `is_group` | bool | True if group chat (style=43) |
| `service` | string | "iMessage" or "SMS" |
| `attachments` | array | File attachments (path, mime type, size) |

## Sending Replies

POST to the local reply server:

```bash
curl -X POST http://localhost:8765/send \
  -H "Content-Type: application/json" \
  -d '{
    "chat_identifier": "chat123456789",
    "text": "Hello from the bot!"
  }'
```

### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check — returns `{"status":"ok"}` |
| `POST` | `/send` | Send a reply — requires `chat_identifier` and `text` |

### Reply Request Format

```json
{
    "chat_identifier": "+14155551234",
    "text": "This is the bot's reply"
}
```

For **group chats**, use the `chat_identifier` from the webhook payload (starts with "chat").
For **DMs**, use the phone number or email address.

### Reply Response

Success:
```json
{"status": "sent"}
```

Error:
```json
{"error": "AppleScript send failed"}
```

## How It Works

```
┌─────────────────────────────────────────────────┐
│                    macOS                         │
│                                                  │
│  iMessage.app ──writes──► chat.db                │
│       ▲                      │                   │
│       │                      │ poll every 2s     │
│  AppleScript              ┌──▼──────────────┐    │
│   (send msg)              │  JerbotRelay    │    │
│       ▲                   │  (menu bar app) │    │
│       │                   └──┬──────────┬───┘    │
│       │                      │          │        │
│  POST /send             POST webhook  GET /health│
│       │                      │          │        │
└───────┼──────────────────────┼──────────┼────────┘
        │                      │          │
        │                      ▼          │
   ┌────┴──────────────────────────────────┐
   │           Your Bot Server             │
   │  (receives messages, sends replies)   │
   └───────────────────────────────────────┘
```

## Differences from BlueBubbles

| | JerbotRelay | BlueBubbles |
|--|-------------|-------------|
| **Dependencies** | None (pure Swift) | Node.js, Firebase, etc |
| **Complexity** | ~500 lines, 4 files | Full server + web UI |
| **Features** | Messages only | Messages, contacts, FaceTime, etc |
| **Stability** | Simple = fewer things break | Complex = more failure modes |
| **Setup** | Build + config file | Server + Firebase + client apps |
| **Connector conflicts** | None — just HTTP in/out | Known Telegram connector issues |

JerbotRelay does one thing: relay messages. If you just need iMessage ↔ bot bridging without the full BlueBubbles stack, this is it.

## Troubleshooting

**"Cannot open chat.db"**
→ Grant Full Disk Access (System Settings → Privacy & Security → Full Disk Access)

**"AppleScript send failed"**
→ Grant Accessibility access to the app (System Settings → Privacy & Security → Accessibility)
→ Make sure Messages.app is running

**No messages appearing**
→ Check that messages are actually arriving in Messages.app
→ Look at the log file: `tail -f ~/Library/Logs/JerbotRelay.log`
→ Verify your webhook URL is correct and reachable

**Port already in use**
→ Change `replyPort` in `~/.jerbot_relay.json` to another port

## License

MIT — do whatever you want with it.
