# CLAUDE.md — Agent Instructions for ClaudeUsageBar

## Project Overview
A native macOS menu bar app that monitors Claude Max subscription usage in real-time.
Shows session (5h) and weekly (7d) utilization with color-coded progress bars.

## Tech Stack
- **Language**: Pure Swift (no Xcode project, no SPM)
- **Frameworks**: AppKit + SwiftUI (NSStatusItem + NSPopover)
- **Target**: macOS 15+, arm64 only
- **Auth**: OAuth via Claude Code CLI tokens (`~/.claude/credentials.json`)
- **Build**: `swiftc` from CommandLineTools — NO Xcode required

## Build Command
```bash
swiftc -o ClaudeUsageBar \
  -target arm64-apple-macosx15.0 \
  -framework AppKit \
  -framework SwiftUI \
  -lsqlite3 \
  Sources/*.swift
```

## File Structure
```
Sources/
├── main.swift          # Entry point (11 lines)
├── AppDelegate.swift   # NSStatusItem + NSPopover + refresh timer
├── UsageAPI.swift      # OAuth token reading + Anthropic API calls + remote mode
├── UsageModel.swift    # Codable data models (UsageResponse, UsageBucket, etc.)
├── OAuthManager.swift  # Reads Claude Code CLI OAuth credentials
├── PopoverView.swift   # SwiftUI popover UI
├── LaunchAtLogin.swift # LaunchAgent helper
└── UsageServer.swift   # Embedded HTTP server for remote clients
```

## Architecture
- `AppDelegate` owns the status item, popover, and refresh timer (5 min interval)
- `UsageAPI.fetchUsage()` is the single data entry point — routes to local (OAuth) or remote (TCP) mode
- `OAuthManager` reads `~/.claude/credentials.json` for OAuth access tokens
- `UsageServer` runs an HTTP server on port 9876 for LAN clients to avoid 429 rate limits
- All UI updates happen on `@MainActor`

## Key Conventions
- **No third-party dependencies** — only Foundation/AppKit/SwiftUI
- **No Xcode project files** — everything builds with `swiftc`
- **Graceful degradation** — every error state (no auth, 429, network error) has a distinct UI state
- **`Sendable` compliance** — data models are `Sendable` for async safety

## Important Constraints
- Do NOT add Package.swift or Xcode project files
- Do NOT add external dependencies
- Do NOT change the build command signature (swiftc with Sources/*.swift)
- Do NOT change the OAuth flow — it reads from Claude Code CLI credentials
- Menu bar text format: `⚡{session}% 📅{weekly}%` — do not change this
- Popover width is 320px — respect this constraint
- The app runs as LSUIElement (no dock icon) — do not change this

## Testing
Currently no automated tests. After making changes, verify:
1. `swiftc` compiles without errors or warnings
2. The binary launches and shows menu bar icon
3. Popover opens/closes correctly
4. Usage data displays (or appropriate error state shows)

## Common Tasks
- **Add a new data model**: Edit `UsageModel.swift`, keep `Codable + Sendable`
- **Add UI**: Edit `PopoverView.swift`, stay within 320px width
- **Add a new feature**: Create a new Swift file in `Sources/`, it auto-includes in build
- **Modify API calls**: Edit `UsageAPI.swift`
