# AgentView 🦉

**A macOS daemon that gives AI agents eyes and hands on the desktop.**

AgentView is a persistent daemon + CLI that lets AI agents see, interact with, and react to any macOS application — through a unified interface that abstracts away three transport layers (Accessibility APIs, Chrome DevTools Protocol, and AppleScript).

The agent never knows which transport is used. It just works.

## Why

Every AI agent framework that tries to "control the computer" hits the same walls:
- **Browser automation disconnects** mid-session
- **Accessibility permissions** break silently
- **Screen locks** kill everything
- **No fallback** — one failure mode = agent stuck in a loop

AgentView solves all of these with a self-healing transport router, persistent connections, and an event-driven daemon that can wake your agent when things happen on the Mac.

## Architecture

```
┌─────────────────────────────────────┐
│          AI Agent (any LLM)         │
│        agentview <cmd> (CLI)        │
└──────────────┬──────────────────────┘
               │ UDS socket
               ▼
┌─────────────────────────────────────┐
│         agentviewd (daemon)         │
│                                     │
│  Router ─── Cache ─── Event Bus     │
│    │                      │         │
│  ┌─┴──────────────────┐   │         │
│  │   Transport Layer   │   │         │
│  │  AX · CDP · Script  │   │         │
│  └─────────────────────┘   │         │
│                            │         │
│  Wake Client ──────────────┘         │
│  (→ webhook → agent wakes up)        │
└─────────────────────────────────────┘
```

## Quick Start

```bash
# Build
/opt/homebrew/opt/swift/bin/swift build -c release

# Install
cp .build/release/agentview ~/.local/bin/
cp .build/release/agentviewd ~/.local/bin/

# Start the daemon
agentview daemon start

# See what's running
agentview list
agentview status
```

## What Can It Do?

### See every app on the Mac
```bash
$ agentview list
[{"name":"Safari","pid":44462},{"name":"Obsidian","pid":73329},{"name":"Notes","pid":75180}...]
```

### Snapshot an app's UI state
```bash
$ agentview snapshot "Obsidian"
# Returns enriched UI elements with refs (e1, e2, e3...) for interaction
```

### Interact with any app
```bash
# Click a button by ref
agentview act "Obsidian" click --ref e3

# Fill a text field
agentview act "Obsidian" fill --ref e5 --value "Hello world"

# Run JavaScript in Electron apps (via CDP)
agentview act "Obsidian" eval --expr 'app.workspace.getActiveFile()?.basename'

# Run AppleScript for native apps
agentview act "Notes" script --expr 'get name of every note of first folder'
```

### One-shot: snapshot + fuzzy match + act
```bash
# Click a button by fuzzy text match — no ref needed
agentview pipe "Notes" click --match "new note"

# Read a specific element
agentview pipe "Obsidian" read --match "sidebar"

# CDP eval (fast path, no AX overhead)
agentview pipe "Obsidian" eval --expr 'app.vault.getFiles().length'
```

### Full system health
```bash
$ agentview status
{
  "daemon": "running",
  "screen": "unlocked",
  "display": "on",
  "frontmost_app": "Safari",
  "transport_health": {"ax": "healthy", "cdp": "healthy", "applescript": "healthy"},
  "apps": [
    {"name": "Obsidian", "available_transports": ["cdp","ax","applescript"], "current_health": {...}},
    {"name": "Notes", "available_transports": ["applescript","ax"], "current_health": {...}}
  ],
  "cache": {"entries": 3, "hit_rate": 0.87},
  "events": {"recent_count": 42, "subscribers": 0}
}
```

### Stream live events
```bash
$ agentview watch --types "app.launched,app.terminated,screen.unlocked"
{"type":"app.launched","app":"Zoom","pid":12345,"timestamp":"2026-02-18T18:30:00Z"}
{"type":"screen.unlocked","timestamp":"2026-02-18T18:31:00Z"}
```

## Three Transports, One Interface

| Transport | What it does | When it works | Best for |
|-----------|-------------|---------------|----------|
| **AX** (Accessibility) | Reads UI tree, clicks buttons, fills fields | Screen unlocked | UI interaction, reading app state |
| **CDP** (Chrome DevTools) | JavaScript eval, DOM access | Always (Electron apps) | Obsidian, VS Code, any Electron app |
| **AppleScript** | Native app scripting, data access | Always (data ops) | Notes, Calendar, Numbers, Safari |

The router picks the best transport automatically and falls back on failure:

```
AX fails? → try CDP → try AppleScript → report honestly
```

You never think about transports. The agent just says "read Notes" and gets the answer.

### Screen Lock Behavior

| | AX | CDP | AppleScript (data) | AppleScript (UI) | Screenshots |
|---|---|---|---|---|---|
| **Unlocked** | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Locked** | ❌ | ✅ | ✅ | ❌ | ❌ |

AgentView handles this automatically — when the screen is locked, it routes to transports that still work.

## The Daemon (agentviewd)

The daemon is the key differentiator. It runs persistently and provides:

- **Persistent CDP connections** — WebSocket stays open to Electron apps. Eval calls go from 31ms (cold) to **7ms** (warm).
- **Snapshot cache** — repeated reads return cached results instantly (5s TTL for AX, 30s for CDP/AppleScript).
- **Screen state detection** — polls `CGSessionCopyCurrentDictionary` every 500ms. Knows if locked/unlocked, display on/off.
- **Event bus** — monitors app lifecycle (launch/terminate/activate) and AX notifications (focus changes, value changes).
- **Self-healing** — CDP auto-reconnects on disconnect with exponential backoff. AppleScript retries with kill-and-retry on hangs.
- **Transport health tracking** — per-app success rates and health status for informed routing decisions.

### Wake Events (Agent Nervous System)

The daemon can wake your AI agent when something happens:

```
Screen unlocks → daemon detects → POST /hooks/wake → agent wakes up
App crashes → daemon detects → writes event file → triggers heartbeat
Dialog appears → daemon detects → agent reads it and reacts
```

Configure in `~/.agentview/config.json`:
```json
{
  "gateway_url": "http://localhost:18789",
  "hooks_token": "your-openclaw-hooks-token",
  "wake_endpoint": "/hooks/wake"
}
```

The daemon writes events to `~/.agentview/pending-event.json` and fires a webhook to wake the agent. The agent reads the event, reacts, and deletes the file.

## Performance

| Operation | Without daemon | With daemon | Improvement |
|-----------|---------------|-------------|-------------|
| `list` | 7ms | 20ms | (UDS overhead) |
| `snapshot` | 191ms | 104ms | **1.8x** |
| CDP `eval` | 31ms | **7ms** | **4.4x** |
| Cached snapshot | N/A | **<10ms** | ∞ |

## Real-World Use Cases

These aren't hypothetical — these are things we actually use AgentView for daily:

### 1. Coding Swarm Completion Detection
When the Parliament (our Claude Code swarm) is running on issues, AgentView watches for the process to exit. Instead of polling log files every 5 minutes, the daemon detects completion instantly and wakes the agent to post results.

### 2. Obsidian Vault Operations (7ms)
Writing daily notes, meeting summaries, and content drafts through CDP eval. Persistent WebSocket connection means every vault operation is 7ms — instant enough to feel like native file I/O.

### 3. Numbers Spreadsheet Access
Reading and updating pipeline data in Apple Numbers via AppleScript. The router automatically picks the right transport whether the screen is locked or unlocked.

### 4. Screen State Awareness
The agent adjusts behavior based on whether you're at the computer:
- Screen unlocks → morning briefing time
- Screen locks → pause UI operations, switch to data-only transports
- Screen unlocks after a meeting → surface anything urgent

### 5. App Health Monitoring
Every heartbeat checks `agentview status` for transport health. If Obsidian's CDP disconnects, the agent proactively warns instead of silently failing on the next vault operation.

### 6. App Recovery
When an Electron app loses its windows (Obsidian windowless bug), `agentview restore` kills and relaunches it via CDP + AppleScript, recovering the workspace without human intervention.

## Benchmarks

Tested against a baseline agent (no AgentView) across 4 scenarios:

| Benchmark | Task | No AgentView | With AgentView |
|-----------|------|-------------|----------------|
| #1 | Create Obsidian note | 8 tool calls | 8 calls (tie) |
| #2 | Read UI state (locked, no hints) | 20+ calls, **crashed** | 11 calls ✅ |
| #3 | Read UI state (fair fight) | 15 calls, ~3 min | **3 calls, 7s** |
| #4 | Numbers read/write/analyze | 5 calls, 1 error | **4 calls, 0 errors** |

The skill file is the game changer — Benchmark #3 proved that giving the agent proper knowledge of AgentView's capabilities reduces tool calls by **5x** and time by **25x**.

## Project Structure

```
Sources/
  AgentViewCore/          # Shared library (models, transports, enrichers)
    AXBridge.swift        # Accessibility API bridge
    AXTreeWalker.swift    # Recursive AX tree traversal
    ActionExecutor.swift  # Click, fill, focus, eval, script actions
    CDPConnectionPool.swift  # Persistent CDP WebSocket connections
    CDPHelper.swift       # CDP protocol helpers
    Enricher.swift        # Raw AX → enriched semantic elements
    Models.swift          # All data models + JSON coding
    ScreenState.swift     # Lock/display detection + polling
    Enhancers/            # Per-app enrichment strategies
  AgentView/              # CLI (thin UDS client)
    AgentView.swift       # All commands (list, snapshot, act, pipe, watch, etc.)
    Client.swift          # UDS JSON-RPC client with daemon auto-start
  AgentViewDaemon/        # Persistent daemon
    main.swift            # Entry point, signal handling, component wiring
    Server.swift          # UDS server + JSON-RPC dispatch
    Router.swift          # Transport router + fallback chain + health tracking
    WakeClient.swift      # Webhook client for agent wake events
```

## Requirements

- macOS 13+
- Swift 5.7+ (Homebrew Swift recommended)
- Accessibility permission granted (System Settings → Privacy → Accessibility)
- For CDP: Electron app with `--remote-debugging-port=9222`
- For AppleScript: target app must support AppleScript

## Roadmap

- [x] **Phase 1**: Daemon + UDS + persistent CDP + screen state (PR #30)
- [x] **Phase 2**: Self-healing router + transport fallback (PR #31)
- [x] **Phase 3**: Snapshot cache + event bus + watch stream (PR #32)
- [ ] **Phase 4**: Safari browser control + semantic page understanding
- [ ] **Phase 5**: Transport-aware enrichers + OCR fallback

## License

MIT
