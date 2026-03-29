# Claude Usage Bar

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
- **Auto-refresh** — Updates every 5 minutes
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
</dict>
</plist>
EOF
launchctl load ~/Library/LaunchAgents/com.claude-usage.chrome-cdp.plist
```

Then open the Chrome CDP window and log in to [claude.ai](https://claude.ai).

### 2. Build & Install

```bash
git clone https://github.com/anthropics/claude-usage-bar.git
cd claude-usage-bar
./build.sh
./install.sh
```

Or build manually:

```bash
./build.sh
cp -r "Claude Usage Bar.app" /Applications/
open "/Applications/Claude Usage Bar.app"
```

### 3. Configuration

The app uses a hardcoded organization ID. To use your own:

1. Open `https://claude.ai/settings/usage` in Chrome DevTools → Network tab
2. Find the request to `/api/organizations/{org-id}/usage`
3. Copy your `org-id` and update it in `Sources/UsageAPI.swift`

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
├── AppDelegate.swift       # NSStatusItem + NSPopover management
├── UsageAPI.swift          # API client with browser-mimicking headers
├── CDPCookieManager.swift  # Chrome DevTools Protocol cookie extraction
├── UsageModel.swift        # Codable data models
└── PopoverView.swift       # SwiftUI popover with progress bars
```

### Cookie Extraction Flow

1. Connect to Chrome CDP browser endpoint via WebSocket
2. Create a hidden target (`about:blank`)
3. Navigate to `claude.ai` to activate cookies
4. Extract cookies via `Network.getCookies`
5. Close the hidden target (no visible tabs opened)
6. Cache cookies for 4 minutes to minimize CDP calls

## Error States

| Menu Bar | Meaning |
|----------|---------|
| `⚡30% 📅19%` | Working normally |
| `⏳ ...` | Loading / first fetch |
| `⛔ CDP` | Chrome CDP not available on port 9222 |
| `🔒 Auth` | Session expired — re-login to claude.ai |
| `⚠️ Error` | Network or API error |

## License

MIT

## Acknowledgments

Built with 🦞 by [OpenClaw](https://github.com/openclaw/openclaw) — an AI agent that codes.
