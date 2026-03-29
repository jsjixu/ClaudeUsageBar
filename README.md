# Claude Usage Bar

**[中文版](README_CN.md)**

<p align="center">
  <img src="screenshots/icon.png" width="128" alt="Claude Usage Bar Icon">
</p>

<p align="center">
  <strong>A native macOS menu bar app that monitors your Claude Max subscription usage in real-time.</strong>
</p>

<p align="center">
  <img src="screenshots/menubar.png" alt="Menu Bar" height="32">
</p>

<p align="center">
  <img src="screenshots/popover.png" alt="Popover Detail View" width="400">
</p>

## Features

- **Menu bar display** — Shows session (5h) and weekly (7d) usage at a glance: `⚡47% 📅20%`
- **Detailed popover** — Click to see progress bars, percentages, and reset countdowns
- **Color-coded** — Green (<50%) → Orange (50-80%) → Red (>80%)
- **Sonnet tracking** — Separate usage tracking for Claude Sonnet
- **Auto-refresh** — Updates every 5 minutes (30s in error states for fast recovery)
- **Remote access** — Monitor usage from any Mac via HTTPS bridge (Surge Ponte, Tailscale, LAN)
- **Session keep-alive** — Persistent background tab prevents session expiry during idle/sleep
- **Auto-retry** — Automatically retries with fresh cookies on auth failure
- **Configurable CDP** — Settings panel to customize Chrome CDP host and port
- **Graceful error handling** — Shows clear status when Chrome CDP is unavailable or auth expires
- **Zero dependencies** — Pure Swift + SwiftUI + AppKit, no third-party libraries
- **Runs silently** — Menu bar only, no Dock icon

## How It Works

Claude Max subscriptions have usage limits but no public API to check them. This app extracts your session cookies from Chrome via the [Chrome DevTools Protocol (CDP)](https://chromedevtools.github.io/devtools-protocol/) and queries the same internal API that `claude.ai/settings/usage` uses.

```
Chrome CDP (port 9222) → Extract cookies → claude.ai/api/organizations/{id}/usage → Menu bar
```

## Requirements

- **macOS 15.0+** (Apple Silicon)
- **Google Chrome** running with `--remote-debugging-port=9222`
- **Logged in** to [claude.ai](https://claude.ai) in the CDP Chrome instance
- **Claude Max** subscription (Pro/Team should also work)

## Setup

### 1. Start Chrome with CDP

Create a LaunchAgent to run Chrome with remote debugging enabled:

```bash
cat > ~/Library/LaunchAgents/com.claude-usage.chrome-cdp.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude-usage.chrome-cdp</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/Google Chrome.app/Contents/MacOS/Google Chrome</string>
        <string>--remote-debugging-port=9222</string>
        <string>--user-data-dir=${HOME}/.chrome-cdp-data</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF
launchctl load ~/Library/LaunchAgents/com.claude-usage.chrome-cdp.plist
```

Then open the Chrome CDP window and log in to [claude.ai](https://claude.ai).

### 2. Build & Install

```bash
git clone https://github.com/jsjixu/ClaudeUsageBar.git
cd ClaudeUsageBar
./build.sh
cp -r "Claude Usage Bar.app" /Applications/
open "/Applications/Claude Usage Bar.app"
```

### 3. Configuration

The app uses a hardcoded organization ID. To use your own:

1. Open `https://claude.ai/settings/usage` in Chrome DevTools → Network tab
2. Find the request to `/api/organizations/{org-id}/usage`
3. Copy your `org-id` and update it in `Sources/UsageAPI.swift`

## Remote Access (Multi-Mac Setup)

Want to check your Claude usage from a MacBook while Chrome CDP runs on a Mac Mini? The app supports remote CDP connections over HTTPS.

### Architecture

```
MacBook                          Mac Mini
┌─────────────┐    HTTPS/WSS    ┌──────────────┐    HTTP/WS    ┌─────────────┐
│ Usage Bar   │ ──────────────→ │ CDP Bridge   │ ────────────→ │ Chrome CDP  │
│ (port 9223) │   Ponte/LAN    │ (port 9223)  │   localhost   │ (port 9222) │
└─────────────┘                 └──────────────┘               └─────────────┘
```

### 1. Generate self-signed certificate (on the Mac running Chrome)

```bash
mkdir -p ~/.openclaw/certs
openssl req -x509 -newkey rsa:2048 \
  -keyout ~/.openclaw/certs/cdp-bridge-key.pem \
  -out ~/.openclaw/certs/cdp-bridge-cert.pem \
  -days 3650 -nodes \
  -subj "/CN=cdp-bridge" \
  -addext "subjectAltName=DNS:your-hostname,DNS:localhost,IP:127.0.0.1"
```

### 2. Set up the HTTPS bridge

Save this as `~/.openclaw/scripts/cdp-bridge.js`:

```javascript
const https = require('https');
const http = require('http');
const fs = require('fs');
const net = require('net');
const path = require('path');

const LISTEN_PORT = 9223;
const CDP_HOST = '127.0.0.1';
const CDP_PORT = 9222;

const CERT_DIR = path.join(process.env.HOME, '.openclaw', 'certs');
const tlsOptions = {
  key: fs.readFileSync(path.join(CERT_DIR, 'cdp-bridge-key.pem')),
  cert: fs.readFileSync(path.join(CERT_DIR, 'cdp-bridge-cert.pem')),
};

const server = https.createServer(tlsOptions, (req, res) => {
  const options = {
    hostname: CDP_HOST, port: CDP_PORT,
    path: req.url, method: req.method,
    headers: { ...req.headers, host: `${CDP_HOST}:${CDP_PORT}` }
  };
  const proxy = http.request(options, (proxyRes) => {
    res.writeHead(proxyRes.statusCode, proxyRes.headers);
    proxyRes.pipe(res);
  });
  proxy.on('error', (e) => { res.writeHead(502); res.end(e.message); });
  req.pipe(proxy);
});

// WebSocket upgrade with Host header rewrite
server.on('upgrade', (req, socket, head) => {
  const target = net.connect(CDP_PORT, CDP_HOST, () => {
    const headers = { ...req.headers, host: `${CDP_HOST}:${CDP_PORT}` };
    let rawReq = `${req.method} ${req.url} HTTP/1.1\r\n`;
    for (const [key, value] of Object.entries(headers))
      rawReq += `${key}: ${value}\r\n`;
    rawReq += '\r\n';
    target.write(rawReq);
    if (head.length) target.write(head);
    target.pipe(socket);
    socket.pipe(target);
  });
  target.on('error', () => socket.destroy());
  socket.on('error', () => target.destroy());
});

server.listen(LISTEN_PORT, '0.0.0.0', () => {
  console.log(`CDP bridge (HTTPS) on 0.0.0.0:${LISTEN_PORT} → ${CDP_HOST}:${CDP_PORT}`);
});
```

### 3. Create a LaunchAgent for the bridge

```bash
cat > ~/Library/LaunchAgents/com.openclaw.cdp-bridge.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.openclaw.cdp-bridge</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/node</string>
        <string>/Users/YOUR_USER/.openclaw/scripts/cdp-bridge.js</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF
launchctl load ~/Library/LaunchAgents/com.openclaw.cdp-bridge.plist
```

### 4. Configure the app on the remote Mac

1. Build and install the app on your remote Mac
2. Click the menu bar icon → **Settings**
3. Set **Host** to your server's hostname (e.g., `my-mac-mini.ponte` or LAN IP)
4. Set **Port** to `9223`
5. Click **Save & Reconnect**

The app automatically uses HTTPS/WSS for remote hosts and accepts self-signed certificates.

### Network Options

| Method | Pros | Cons |
|--------|------|------|
| **Surge Ponte** | Works anywhere, no port forwarding | Requires Surge license |
| **Tailscale** | Free, works anywhere | Requires Tailscale setup |
| **LAN IP** | Simplest, no setup | Only works on same network |

## Build from Source

Requires only Xcode Command Line Tools (no full Xcode needed):

```bash
xcode-select --install  # if not already installed
./build.sh
```

The build script compiles with `swiftc` and produces a signed `.app` bundle.

## Architecture

```
Sources/
├── main.swift              # App entry point
├── AppDelegate.swift       # NSStatusItem + NSPopover + adaptive refresh
├── UsageAPI.swift          # API client with auto-retry on auth failure
├── CDPCookieManager.swift  # CDP cookie extraction + persistent tab keep-alive
├── UsageModel.swift        # Codable data models
├── PopoverView.swift       # SwiftUI popover with progress bars
└── SettingsView.swift      # CDP host/port configuration panel
```

### Cookie Extraction Flow

1. Connect to Chrome CDP browser endpoint via WebSocket (WS or WSS)
2. Reuse persistent `claude.ai` background tab (or create one if missing)
3. Extract cookies via `Network.getCookies`
4. Detach from tab but keep it alive (frontend JS maintains session)
5. Cache cookies for 4 minutes to minimize CDP calls
6. On auth failure: invalidate cache, clean up old tabs, retry with fresh cookies

### Session Keep-Alive

The app maintains a persistent `claude.ai` tab in Chrome CDP. The Claude frontend JavaScript automatically refreshes the session token, preventing auth expiry during idle periods or screen lock. Old tabs are automatically cleaned up to prevent accumulation.

### Adaptive Refresh Rate

| State | Refresh Interval |
|-------|-----------------|
| Healthy (`⚡%`) | Every 5 minutes |
| Error / Auth / CDP | Every 30 seconds |

This ensures fast recovery after re-login without wasting resources during normal operation.

## Error States

| Menu Bar | Meaning |
|----------|---------|
| `⚡30% 📅19%` | Working normally |
| `⏳ ...` | Loading / first fetch |
| `⛔ CDP` | Chrome CDP not available |
| `🔒 Auth` | Session expired — re-login to claude.ai |
| `⚠️ Error` | Network or API error |

## Security Notes

- **Chrome CDP (port 9222)** listens on `127.0.0.1` only — not accessible from the network
- **CDP Bridge (port 9223)** listens on `0.0.0.0` — only enable when you need remote access
- The bridge uses HTTPS with a self-signed certificate — traffic is encrypted
- No data is sent to any third-party server — all communication is between your devices
- Consider adding authentication to the bridge if your network is untrusted

## License

MIT

## Acknowledgments

Built with 🦞 by [OpenClaw](https://github.com/openclaw/openclaw) — an AI agent that codes.
