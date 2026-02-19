# Architecture

cua is a persistent daemon + CLI that abstracts macOS UI interaction behind a unified transport layer.

## System Overview

```
┌─────────────────────────────────────┐
│          AI Agent (any LLM)         │
│        cua <cmd> (CLI)        │
└──────────────┬──────────────────────┘
               │ UDS socket (~/.cua/sock)
               ▼
┌─────────────────────────────────────┐
│         cuad (daemon)         │
│                                     │
│  Router ─── Cache ─── Event Bus     │
│    │                      │         │
│  ┌─┴──────────────────┐   │         │
│  │   Transport Layer   │   │         │
│  │ AX·CDP·Script·Safari│   │         │
│  └─────────────────────┘   │         │
│                            │         │
│  Wake Client ──────────────┘         │
│  (→ webhook → agent wakes up)        │
└─────────────────────────────────────┘
```

## Transport Layer

Each transport implements: `canHandle(app) → Bool`, `health() → Status`, `execute(action) → Result`

### AX Transport (Accessibility APIs)
- Direct macOS Accessibility API calls
- Works when screen is unlocked and app has windows
- Richest data: full UI tree with roles, labels, values, actions
- Fastest for UI interaction (click, fill, focus)

### CDP Transport (Chrome DevTools Protocol)
- Persistent WebSocket connections to Electron apps + Chrome
- Auto-reconnect with exponential backoff (1s → 2s → 4s → 8s → 30s max)
- Works always for Electron apps (Obsidian, VS Code, Docker Desktop)
- Port discovery: scans known ports (9222, 9229)

### AppleScript Transport
- osascript execution with configurable timeout (default 3s)
- Kill-and-retry on hang
- Works for data-level ops always; UI ops when unlocked
- App-specific templates (Notes, Safari, Calendar, Numbers)

### Safari Transport (AppleScript + `do JavaScript`)
- Hybrid: AppleScript for tab management + JS injection for page content
- **Works even when screen is locked** — the killer feature
- Tab management: list, switch, open, close
- Page analysis: semantic type detection, content extraction, form filling
- Fuzzy element matching via injected JS

### Router Logic
```
For each action:
  1. Check screen state (locked/unlocked)
  2. Check available transports for target app
  3. Pick best transport (AX > Safari > CDP > AppleScript)
  4. Execute with timeout
  5. On failure: automatically try next transport
  6. Return result + which transport was used
```

## Daemon Components

### State Cache
- In-memory snapshot cache per app (keyed by name/bundleId)
- TTL: 5s for AX, 30s for CDP/AppleScript
- Ref stability: `e1` stays `e1` as long as element exists (matched by role+title+identifier)
- Tombstoned refs not reused for 60s
- Hit/miss stats tracking

### Event Bus
- NSWorkspace notifications: app launched/terminated/activated/deactivated
- AX notifications: focus changed, value changed, window created/destroyed
- Screen state changes: lock/unlock, display sleep/wake
- Subscriber callbacks with optional filters
- Stores last 100 events

### Wake Client
- Fires webhook to OpenClaw gateway on screen events
- Agent wakes up when screen unlocks, app activates, etc.
- Writes events to `~/.cua/pending-event.json`

## JSON-RPC Protocol

All communication over UDS socket at `~/.cua/sock` using JSON-RPC 2.0.

### Methods
| Method | Description |
|--------|-------------|
| `ping` | Health check |
| `list` | List running GUI apps |
| `snapshot` | Enriched UI snapshot of an app |
| `act` | Perform action (click, fill, focus, etc.) |
| `pipe` | Snapshot + fuzzy match + act in one call |
| `status` | Full system status |
| `subscribe` | Stream events (for `watch` command) |
| `web.tabs` | List Safari tabs |
| `web.navigate` | Open URL in Safari |
| `web.snapshot` | Semantic page analysis |
| `web.click` | Fuzzy click on page element |
| `web.fill` | Fuzzy fill form field |
| `web.extract` | Page content as markdown |
| `web.switchTab` | Switch tab by fuzzy match |
| `screenshot` | Capture window as PNG |

## Performance

| Operation | Without daemon | With daemon | Improvement |
|-----------|---------------|-------------|-------------|
| `list` | 7ms | 20ms | (UDS overhead) |
| `snapshot` | 191ms | 104ms | **1.8x** |
| CDP `eval` | 31ms | **7ms** | **4.4x** |
| Cached snapshot | N/A | **<10ms** | ∞ |
| `web snapshot` | N/A | ~300ms | — |
| `web click` | N/A | ~200ms | — |

## Project Structure

```
Sources/
  CUACore/             # Shared library
    AXBridge.swift           # Accessibility API bridge
    AXTreeWalker.swift       # Recursive AX tree traversal
    ActionExecutor.swift     # Click, fill, focus, eval, script
    CDPConnectionPool.swift  # Persistent CDP WebSocket connections
    SafariTransport.swift    # AppleScript + do JavaScript hybrid
    AppleScriptTransport.swift  # Generic AppleScript with retry
    TransportRouter.swift    # Auto-fallback chain
    SnapshotCache.swift      # TTL cache + ref stability
    EventBus.swift           # Event monitoring + subscribers
    PageAnalyzer.swift       # Semantic page type detection
    WebElementMatcher.swift  # Fuzzy element matching via JS
    ScreenCapture.swift      # Window screenshots via CGWindowList
    ScreenState.swift        # Lock/display detection
    Enricher.swift           # Raw AX → semantic elements
    Enhancers/               # Per-app enrichment strategies
  CUA/                 # CLI (thin UDS client)
    CUA.swift                # All commands
    Client.swift             # UDS JSON-RPC client + daemon auto-start
  CUADaemon/           # Persistent daemon
    main.swift               # Entry point, component wiring
    Server.swift             # UDS server + JSON-RPC dispatch
    Router.swift             # Request routing + transport selection
    WakeClient.swift         # Webhook client for agent wake events
```

## Requirements

- macOS 13+
- Swift 5.7+ (Homebrew Swift recommended)
- Accessibility permission (System Settings → Privacy → Accessibility)
- For CDP: Electron app with `--remote-debugging-port=9222`
- Safari: requires "Allow JavaScript from Apple Events" in Develop menu
