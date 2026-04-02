# Claude Usage Bar

**[中文版](README_CN.md)**

<p align="center">
  <img src="screenshots/icon.png" width="128" alt="Claude Usage Bar Icon">
</p>

<p align="center">
  <strong>A native macOS menu bar app that shows your Claude session and weekly usage in real-time.</strong>
</p>

<p align="center">
  <img src="screenshots/menubar.png" alt="Menu Bar" height="40">
</p>

<p align="center">
  <img src="screenshots/popover.png" alt="Usage View" width="320">
  <img src="screenshots/stats.png" alt="Stats Overview" width="320">
</p>

<p align="center">
  <img src="screenshots/stats-chart.png" alt="Activity Charts" width="320">
</p>

## Features

- **Real-time status bar** — Always visible: `⚡35% 📅4%` shows session (5h) and weekly (7d) usage at a glance
- **One-click login** — Click the login button to launch `claude auth login` in your browser — no terminal needed
- **Auto-refresh after login** — Polls every 2 seconds after login; detects new credentials and updates usage automatically
- **Delegated CLI Refresh** — When tokens expire, automatically triggers `claude -p ping` to refresh via CLI, avoiding OAuth rate limits
- **Smart token resolution** — Multi-source credential priority: CLI Proxy API → memory cache → Keychain → credentials.json → Delegated CLI → OAuth refresh
- **FailureGate protection** — Dual-layer failure gate: terminal block for `invalid_grant`, transient backoff for 429/network errors; Keychain+File fingerprint auto-unlocks when credentials change
- **Reset countdowns** — Know exactly when each usage window resets
- **Per-model tracking** — Separate Sonnet and Opus weekly usage
- **Color-coded** — Green (<50%) → Orange (50–80%) → Red (>80%)
- **Stats panel** — Usage history with Usage tab and Stats tab
- **Launch at Login** — One-click toggle in the popover
- **Zero dependencies** — Pure Swift + SwiftUI + AppKit, no third-party libraries
- **Privacy-first** — Reads local OAuth credentials, calls Anthropic API directly, no third-party servers
- **Runs silently** — Menu bar only, no Dock icon

## How It Works

Reads OAuth credentials from Claude Code CLI (macOS Keychain or `~/.claude/.credentials.json`) and calls the official Anthropic usage API.

```
Claude Code CLI credentials (Keychain / ~/.claude/.credentials.json)
  → OAuthManager (multi-source with auto-refresh)
  → api.anthropic.com/api/oauth/usage
  → Menu bar + Popover
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

## Authentication & Token Management

ClaudeUsageBar uses a multi-source credential resolution chain to keep your session alive without manual intervention.

### Credential Priority

| Priority | Source | Description |
|----------|--------|-------------|
| 1 | **CLI Proxy API** | Fastest — reads token directly from the Claude CLI daemon |
| 2 | **Memory cache** | In-process cache from previous successful read |
| 3 | **Keychain** | macOS Keychain stored by Claude Code CLI |
| 4 | **credentials.json** | `~/.claude/.credentials.json` file fallback |
| 5 | **Delegated CLI Refresh** | Runs `claude -p ping` to trigger a token refresh via CLI |
| 6 | **OAuth refresh** | Direct OAuth refresh as last resort |

### Delegated CLI Refresh

When a token expires and direct OAuth refresh would hit rate limits, ClaudeUsageBar automatically runs `claude -p ping` in the background. This delegates the token refresh to the Claude CLI process, which handles its own OAuth flow and rate limiting gracefully. The app then picks up the refreshed token from Keychain or credentials.json.

### FailureGate Dual-Layer Protection

| Layer | Trigger | Behavior |
|-------|---------|----------|
| **Terminal block** | `invalid_grant` error | Stops retry attempts entirely; waits for credential change (Keychain or file fingerprint) to unlock |
| **Transient backoff** | 429 / network errors | Exponential backoff; resumes automatically when errors clear |

The gate monitors both Keychain and `~/.claude/.credentials.json` fingerprints. As soon as you log in again (via one-click login or `claude auth login`), the new credential fingerprint automatically unlocks the gate and resumes fetching.

### One-Click Login Flow

1. Click **Login** in the popover → `claude auth login` launches in your browser
2. App polls every 2 seconds for new credentials
3. Once detected, usage data loads automatically — no manual refresh needed

## Status Icons

| Menu Bar | Meaning |
|----------|---------|
| `⚡35% 📅4%` | Working normally |
| `⏳ ...` | Loading |
| `🔑 Login` | Not logged in — click Login button in popover |
| `🔒 Auth` | Token expired — app will attempt Delegated CLI Refresh automatically |
| `⚠️ Error` | API error (rate limit, network, etc.) — transient backoff in progress |

## Architecture

```
Sources/
├── main.swift             # App entry point
├── AppDelegate.swift      # Status item + popover + adaptive refresh + credentials watcher + login poll
├── OAuthManager.swift     # Multi-source credential reader + DelegatedCLIRefresh
├── OAuthFailureGate.swift # Dual-layer failure gate with Keychain+File fingerprint
├── UsageAPI.swift         # Anthropic OAuth usage API
├── UsageModel.swift       # Codable data models
├── UsageStore.swift       # Usage history persistence
├── PopoverView.swift      # SwiftUI popover with usage bars + login flow + remote config
├── StatsView.swift        # Usage statistics and heatmap
└── LaunchAtLogin.swift    # LaunchAgent-based auto-start
```

## Configuration

The app reads Claude Code credentials automatically. No manual configuration needed.

## License

MIT

## Acknowledgments

Built with 🦞 by [OpenClaw](https://github.com/openclaw/openclaw) — an AI agent that codes.
