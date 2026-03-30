# Claude Usage Bar

**[中文版](README_CN.md)**

<p align="center">
  <img src="screenshots/icon.png" width="128" alt="Claude Usage Bar Icon">
</p>

<p align="center">
  <strong>A native macOS menu bar app that shows your Claude session and weekly usage in real-time.</strong>
</p>

<p align="center">
  <img src="screenshots/menubar.png" alt="Menu Bar" height="32">
</p>

<p align="center">
  <img src="screenshots/popover.png" alt="Popover Detail View" width="400">
</p>

## Features

- **Real-time status bar** — Always visible: `⚡0% 📅24%` shows session (5h) and weekly (7d) usage at a glance
- **Reset countdowns** — Know exactly when each usage window resets
- **Per-model tracking** — Separate Sonnet and Opus weekly usage
- **Color-coded** — Green (<50%) → Orange (50-80%) → Red (>80%)
- **Auto-refresh** — Every 5 minutes; 30s when recovering from errors
- **Multi-machine support** — Share usage data across Macs without hitting rate limits (see [Remote Mode](#remote-mode))
- **Launch at Login** — One-click toggle in the popover
- **Zero dependencies** — Pure Swift + SwiftUI + AppKit, no third-party libraries
- **Privacy-first** — Reads local OAuth credentials, calls Anthropic API directly, no third-party servers
- **Runs silently** — Menu bar only, no Dock icon

## How It Works

Reads OAuth credentials from Claude Code CLI (macOS Keychain) and calls the official Anthropic usage API.

```
Claude Code OAuth token (Keychain) → api.anthropic.com/api/oauth/usage → Menu bar
```

No browser, no cookies, no Chrome DevTools Protocol.

## Requirements

- **macOS 15.0+** (Apple Silicon)
- **Claude Code CLI** installed and logged in
- **Claude Max** subscription (Pro/Team should also work)

## Install

### 1. Install Claude Code CLI (if not already)

```bash
npm install -g @anthropic-ai/claude-code
claude  # Log in via browser, then Ctrl+C
```

### 2. Build & Install

```bash
git clone https://github.com/jsjixu/ClaudeUsageBar.git
cd ClaudeUsageBar
./build.sh
cp -r "Claude Usage Bar.app" /Applications/
open "/Applications/Claude Usage Bar.app"
```

Requires only Xcode Command Line Tools (no full Xcode):

```bash
xcode-select --install  # if not already installed
```

### 3. Enable Launch at Login

Click the menu bar icon → toggle **Launch at Login**.

## Remote Mode

**Problem:** Running ClaudeUsageBar on multiple Macs causes 429 rate limit errors — Anthropic's usage API is aggressively rate-limited.

**Solution:** One Mac queries the API (server), other Macs read cached data from it (client). Zero API calls from client machines.

```
┌─────────────────────┐         ┌─────────────────────┐
│   Mac A (server)    │         │   Mac B (client)     │
│                     │         │                      │
│  OAuth → Anthropic  │  HTTP   │  Remote → Mac A      │
│  API every 5 min    │◄───────►│  reads cached JSON   │
│  + serves on :9876  │         │  0 API calls         │
│  badge: [LOCAL]     │         │  badge: [REMOTE]     │
└─────────────────────┘         └──────────────────────┘
```

### Setup

#### Server (the Mac that queries Anthropic)

Nothing to do — the embedded HTTP server starts automatically on port **9876** in local mode.

Verify it's running:
```bash
curl http://127.0.0.1:9876/usage
```

#### Client (other Macs)

**Option A: Pre-configure before first launch** (recommended — avoids any API calls)

```bash
defaults write ClaudeUsageBar remote_usage_url "http://<server-host>:9876"
open "/Applications/Claude Usage Bar.app"
```

**Option B: Configure in the app**

Click the menu bar icon → expand **Remote Mode** → enter the server URL → **Save & Restart**.

### Network Options

The client just needs HTTP access to the server's port 9876. Some options:

| Method | URL example | Notes |
|--------|-------------|-------|
| Same LAN | `http://192.168.1.100:9876` | Simplest — both Macs on same Wi-Fi/network |
| [Surge Ponte](https://manual.nssurge.com/others/ponte.html) | `http://mymac.sgponte:9876` | Access your home Mac from anywhere, no port forwarding |
| Tailscale | `http://my-mac-mini.tail12345.ts.net:9876` | Similar to Ponte but cross-platform |
| SSH tunnel | `http://127.0.0.1:9876` (after `ssh -L 9876:127.0.0.1:9876 user@server`) | Works anywhere with SSH access |

### Surge Ponte Setup (detailed)

[Surge Ponte](https://manual.nssurge.com/others/ponte.html) lets you access devices on your home network from anywhere via Surge's proxy mesh — no public IP, no port forwarding, no VPN needed.

**Prerequisites:**
- [Surge for Mac](https://nssurge.com) on both machines
- Ponte enabled on the server Mac (the one running in LOCAL mode)
- Both Macs signed into the same Surge account / iCloud team

**Steps:**

1. **Server Mac:** Enable Ponte in Surge → Dashboard → Ponte. Note the hostname (e.g., `my-mac-mini.sgponte`).

2. **Client Mac:** Ensure Surge is running with Enhanced Mode or set as system proxy. Verify connectivity:
   ```bash
   curl http://my-mac-mini.sgponte:9876/usage
   ```

3. **Configure ClaudeUsageBar on client:**
   ```bash
   defaults write ClaudeUsageBar remote_usage_url "http://my-mac-mini.sgponte:9876"
   ```

**Troubleshooting Ponte:**

- **Connection refused** — Check that ClaudeUsageBar is running on the server Mac and port 9876 is listening (`lsof -i :9876`)
- **Cannot resolve .sgponte** — Ensure Surge is running with Enhanced Mode on the client Mac
- **ATS blocks HTTP** — This app uses raw TCP sockets for remote fetching, which bypasses macOS App Transport Security entirely. If you still see ATS errors, make sure you're running the latest version.

### How It Works Internally

- **Local mode (server):** The app starts a lightweight TCP server (via `Network.framework` `NWListener`) on port 9876. Every time it fetches fresh data from Anthropic, it caches the JSON response. Any HTTP GET to `/usage` returns the cached JSON with an `X-Cached-Age` header showing staleness in seconds.

- **Remote mode (client):** Instead of calling Anthropic's API, the app connects to the server URL via a raw TCP socket (bypassing ATS), sends a minimal HTTP/1.1 GET, and decodes the same `UsageResponse` JSON. The UI is identical — you can't tell the difference except for the blue `REMOTE` badge.

## Status Icons

| Menu Bar | Meaning |
|----------|---------|
| `⚡12% 📅24%` | Working normally |
| `⏳ ...` | Loading |
| `🔒 Auth` | Token expired — run `claude` to refresh |
| `🔑 No Key` | No credentials — install Claude Code CLI and log in |
| `⚠️ Error` | API error (rate limit, network, etc.) |

## Architecture

```
Sources/
├── main.swift           # App entry point
├── AppDelegate.swift    # Status item + popover + adaptive refresh + Edit menu for paste
├── OAuthManager.swift   # Keychain + file credential reader
├── UsageAPI.swift       # Anthropic OAuth API (local) + raw TCP remote fetcher (client)
├── UsageServer.swift    # Embedded HTTP server for multi-machine sharing
├── UsageModel.swift     # Codable data models
├── PopoverView.swift    # SwiftUI popover with progress bars + remote mode config
└── LaunchAtLogin.swift  # LaunchAgent-based auto-start toggle
```

## Configuration

The app reads Claude Code credentials automatically. No manual configuration needed for single-machine use.

For multi-machine setups, see [Remote Mode](#remote-mode).

## License

MIT

## Acknowledgments

Built with 🦞 by [OpenClaw](https://github.com/openclaw/openclaw) — an AI agent that codes.
