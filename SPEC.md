# ClaudeUsageBar — macOS Menu Bar Usage Monitor

## Overview
A native macOS SwiftUI menu bar app that shows Claude Max subscription usage in real-time.

## Data Source
- **API Endpoint**: `GET https://claude.ai/api/organizations/{org_id}/usage`
- **Org ID**: `ec954bf6-ee1a-418e-92d1-bef93b5faed9`
- **Auth**: Session cookie from Chrome CDP on `127.0.0.1:9222`
- **Cookie extraction**: Connect to CDP via WebSocket, execute `document.cookie` on a claude.ai page to get the session cookie. Or use `Network.getCookies` CDP method for the claude.ai domain.

## CDP Cookie Extraction Flow
1. HTTP GET `http://127.0.0.1:9222/json` → get list of browser targets
2. Find any target with url containing `claude.ai`, or use any page target
3. Connect WebSocket to target's `webSocketDebuggerUrl`
4. Send CDP command: `{"id":1,"method":"Network.getCookies","params":{"urls":["https://claude.ai"]}}`
5. Extract cookies, format as `Cookie: name1=value1; name2=value2` header
6. Use that header to call the usage API via URLSession

## API Response Format
```json
{
  "five_hour": {
    "utilization": 30.0,
    "resets_at": "2026-03-29T18:00:01.400349+00:00"
  },
  "seven_day": {
    "utilization": 19.0,
    "resets_at": "2026-04-01T15:00:00.400372+00:00"
  },
  "seven_day_sonnet": {
    "utilization": 1.0,
    "resets_at": "2026-04-03T02:00:00.400382+00:00"
  },
  "extra_usage": {
    "is_enabled": false,
    "monthly_limit": null,
    "used_credits": null,
    "utilization": null
  }
}
```

## UI Design

### Menu Bar Icon
- Show text in menu bar: `⚡30% 📅19%` (session% weekly%)
- Color coding based on the HIGHER of the two values:
  - < 50%: green (system green)
  - 50-80%: yellow/orange
  - > 80%: red

### Popover (click to expand)
Show a clean card with:

1. **Session Usage (5h)**
   - Progress bar with percentage
   - "Resets in X h Y m"
   
2. **Weekly Usage (7d)**
   - Progress bar with percentage
   - "Resets in X d Y h"

3. **Sonnet Usage (7d)**
   - Progress bar with percentage (if available)
   - "Resets in X d Y h"

4. **Footer**
   - Last refreshed timestamp
   - "Refresh" button
   - "Quit" option

### Color for progress bars
- Green gradient for < 50%
- Yellow/Orange for 50-80%  
- Red for > 80%

## Technical Requirements

### Build
- Pure Swift + SwiftUI + AppKit (NSStatusItem for menu bar)
- Compile with `swiftc` (no Xcode required, only CommandLineTools)
- Target: macOS 15+ (arm64)
- Single file or minimal files, compile to standalone binary

### Architecture
- `App` with `MenuBarExtra` (macOS 13+)
- `NSStatusItem` + `NSPopover` approach for better control
- Timer-based refresh every 5 minutes
- `URLSession` for HTTP requests
- JSON decoding with `Codable`

### Cookie Management
- On launch and every refresh cycle, fetch cookies from CDP
- If CDP is unavailable (Chrome not running), show "⚠️ No Chrome" in menu bar
- If cookies are expired (API returns 401/403), show "🔒 Login needed"

### Error States
- CDP not reachable → gray icon, "Chrome CDP not available"
- Auth expired → "🔒" icon, prompt to login
- Network error → show last known values with "(stale)" indicator

### App Behavior
- Runs as LSUIElement (no dock icon)
- Launch at login option (LaunchAgent)
- Lives only in menu bar

## File Structure
```
ClaudeUsageBar/
├── SPEC.md
├── Sources/
│   ├── main.swift          # Entry point
│   ├── AppDelegate.swift   # NSStatusItem + NSPopover setup  
│   ├── UsageAPI.swift      # CDP cookie extraction + API calls
│   ├── UsageModel.swift    # Data models
│   └── PopoverView.swift   # SwiftUI popover content
├── Info.plist              # LSUIElement = true
├── build.sh                # Compile script
└── install.sh              # Install LaunchAgent
```

## Build Command
```bash
swiftc -o ClaudeUsageBar \
  -target arm64-apple-macosx15.0 \
  -framework AppKit \
  -framework SwiftUI \
  Sources/*.swift
```

## Important Notes
- No third-party dependencies — pure Foundation/AppKit/SwiftUI
- The CDP WebSocket connection uses raw URLSessionWebSocketTask (available since macOS 13)
- Must handle the WebSocket protocol correctly for Chrome DevTools Protocol
- The app should be resilient — if CDP or API fails, degrade gracefully
- Refresh interval: 5 minutes default
