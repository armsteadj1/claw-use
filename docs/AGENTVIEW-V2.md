# AgentView v2 — The Universal UI Layer

**Vision**: One daemon, every app, every transport, always on. The agent's eyes and hands on macOS.

## Architecture

```
┌─────────────────────────────────────────────┐
│                  Agent (Hedwig, sub-agents)  │
│            agentview <cmd> (CLI client)      │
└──────────────────┬──────────────────────────┘
                   │ UDS socket (~/.agentview/sock)
                   ▼
┌─────────────────────────────────────────────┐
│              agentviewd (daemon)             │
│                                             │
│  ┌─────────┐  ┌──────┐  ┌──────────────┐   │
│  │ State   │  │Router│  │ Event Bus    │   │
│  │ Cache   │  │      │  │ (push model) │   │
│  └────┬────┘  └──┬───┘  └──────┬───────┘   │
│       │          │              │            │
│  ┌────▼──────────▼──────────────▼────────┐  │
│  │         Transport Layer               │  │
│  │                                       │  │
│  │  ┌────┐  ┌────┐  ┌──────────┐  ┌───┐ │  │
│  │  │ AX │  │CDP │  │AppleScript│  │OCR│ │  │
│  │  └────┘  └────┘  └──────────┘  └───┘ │  │
│  └───────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
         │          │          │          │
    Finder,    Obsidian,   Notes,     Locked
    Safari     VS Code    Calendar    screen
    (any app)  Electron   Numbers     fallback
```

## Components

### 1. Daemon (`agentviewd`)
- Long-running process, launches at login (or on first `agentview` call)
- Listens on UDS socket: `~/.agentview/sock`
- JSON-RPC protocol over UDS (simple request/response + event push)
- CLI becomes a thin client: `agentview snapshot "Notes"` → sends JSON-RPC to daemon → returns result
- Auto-starts if not running when CLI is invoked

### 2. Transport Layer (self-healing, auto-routing)
Each transport is a module with: `canHandle(app) -> Bool`, `health() -> Status`, `execute(action) -> Result`

**AX Transport**
- Direct Accessibility API calls (current implementation)
- Works: screen unlocked, app has windows
- Fails: screen locked, no windows, permission denied

**CDP Transport**
- Persistent WebSocket connections to Electron apps + Chrome/Chromium
- Auto-reconnect on disconnect (exponential backoff, max 3 retries)
- Works: always (Electron), Chrome with --remote-debugging-port
- Port discovery: scan known ports (9222, 9229), read Electron debug flags

**AppleScript Transport**  
- osascript execution with timeout + retry
- Works: data-level ops always, UI ops when unlocked
- Kill + retry on hang (current 3s timeout, bump to configurable)
- App-specific script templates (Notes, Calendar, Numbers, Safari, Mail)

**Safari Transport** (NEW — subset of CDP + AppleScript hybrid)
- `do JavaScript` via AppleScript for page content/manipulation
- AX for UI chrome (tabs, address bar, bookmarks bar)
- Tab management via AppleScript (`tell application "Safari" to get URL of every tab`)
- Semantic page understanding (extract forms, links, headings, main content)

**OCR Transport** (NEW — last resort fallback)
- `screencapture` → Vision framework text recognition
- Works: when screen is on but locked (display not sleeping)
- Returns: detected text with approximate positions
- Use case: reading dialogs, alerts, or state when all other transports fail

**Router Logic:**
```
For each action:
  1. Check screen state (locked/unlocked via CGSessionCopyCurrentDictionary)
  2. Check available transports for target app
  3. Pick best transport (preference: AX > CDP > AppleScript > OCR)
  4. Execute with timeout
  5. On failure: automatically try next transport
  6. Return result + which transport was used
```

### 3. State Cache + Diff Engine
- Cache last snapshot per app (in-memory)
- On re-snapshot: diff against cache, only walk changed subtrees
- Ref stability: maintain ref→element mapping across snapshots
  - `e1` stays `e1` as long as the element exists
  - New elements get next available ref
  - Deleted elements are tombstoned (ref not reused for 60s)
- Cache TTL: 5s for AX (UI changes frequently), 30s for CDP/AppleScript data

### 4. Event Bus (push model)
- Daemon watches for app lifecycle events (NSWorkspace notifications):
  - App launched / terminated
  - App activated / deactivated  
  - Window created / closed / moved / resized
- AX notifications (kAXValueChanged, kAXFocusedUIElementChanged, etc.)
- Screen state changes (lock/unlock, display sleep/wake)
- Events pushed to connected clients via UDS
- CLI can long-poll: `agentview watch` → streams events as JSON lines

### 5. Semantic Enrichment v2
- Per-app enrichers become **transport-aware**:
  - Safari enricher: combines AX (toolbar/tabs) + AppleScript (page content) + JS injection (DOM structure)
  - Numbers enricher: AppleScript for cell data + AX for UI state
  - Obsidian enricher: CDP for vault/note content + AX for UI chrome
- **Page type detection** for web content:
  - Login form → extract fields, suggest fill
  - Search results → extract result list with titles/URLs/snippets
  - Article → extract title, author, main content, reading time
  - Table/data → extract structured rows/columns
  - Generic → headings + links + forms + main text
- Output is always high-level semantic, never raw tree

### 6. Web Browsing (the killer feature)
AgentView becomes the universal browser driver:

```
agentview web navigate "https://example.com"     # open URL in default browser
agentview web snapshot                            # semantic page snapshot
agentview web click --match "Sign In"             # fuzzy click
agentview web fill --match "email" --value "..."  # fuzzy fill  
agentview web extract                             # main content as markdown
agentview web tabs                                # list all tabs
agentview web tab --match "GitHub"                # switch to tab
```

Under the hood:
- Safari: AppleScript navigation + `do JavaScript` for DOM + AX for chrome
- Chrome: CDP for everything (if remote debugging enabled)
- Fallback: AppleScript `open location` + OCR

**Why this beats OpenClaw's browser tool:**
- No managed browser needed — uses whatever's already open
- No gateway connectivity issues — it's local
- No Playwright dependency — native macOS APIs
- Works with Safari (Apple's browser, best macOS integration)
- Self-healing: if one transport fails, tries the next

### 7. Status Command
```
agentview status
```
Returns:
```json
{
  "daemon": "running",
  "pid": 12345,
  "uptime_s": 3600,
  "screen": "locked",
  "display": "on",
  "frontmost_app": "Safari",
  "apps": [
    {"name": "Safari", "transports": ["applescript", "ax_when_unlocked"], "health": "ok"},
    {"name": "Obsidian", "transports": ["cdp", "ax_when_unlocked"], "health": "ok"},
    {"name": "Notes", "transports": ["applescript"], "health": "ok"}
  ],
  "cache": {"entries": 5, "hit_rate": 0.87},
  "events_queued": 2
}
```

## CLI Interface (v2)

All commands become thin UDS clients. Daemon auto-starts if needed.

```bash
# Daemon management
agentview daemon start|stop|status

# Current commands (unchanged API, now via daemon)
agentview list
agentview snapshot <app>
agentview act <app> <action> [--ref|--match|--expr|--value]
agentview pipe <app> <action> --match <fuzzy> [--value]
agentview restore <app>

# New commands
agentview status                    # full system status
agentview watch [--app <name>]      # stream events as JSONL
agentview web navigate <url>        # browser control
agentview web snapshot              # semantic page snapshot  
agentview web click --match <text>  # fuzzy click on page
agentview web fill --match <text> --value <val>
agentview web extract               # page content as markdown
agentview web tabs                  # list browser tabs
agentview web tab --match <text>    # switch tab
```

## Implementation Phases

### Phase 1: Daemon + UDS (foundation)
- [ ] `agentviewd` daemon with UDS socket + JSON-RPC
- [ ] CLI thin client (all existing commands route through daemon)
- [ ] Auto-start daemon on first CLI call
- [ ] `agentview daemon start|stop|status`
- [ ] Persistent CDP connections (Obsidian, VS Code)
- [ ] Screen state detection (`CGSessionCopyCurrentDictionary`)

### Phase 2: Self-healing Router
- [ ] Transport health monitoring + auto-fallback chain
- [ ] CDP auto-reconnect with exponential backoff
- [ ] AppleScript retry logic (kill hung + retry once)
- [ ] Transport preference per app (configurable)
- [ ] `agentview status` command with transport health

### Phase 3: State Cache + Events
- [ ] In-memory snapshot cache with TTL
- [ ] Ref stability across snapshots (persistent ref mapping)
- [ ] NSWorkspace event monitoring (app lifecycle)
- [ ] AX notification observers (focus, value changes)
- [ ] Screen lock/unlock detection
- [ ] `agentview watch` event stream

### Phase 4: Safari + Web Browsing
- [ ] Safari AppleScript transport (tabs, navigation, `do JavaScript`)
- [ ] Semantic page type detection (login, search, article, table, generic)
- [ ] `agentview web` command family
- [ ] Page content extraction as markdown
- [ ] Fuzzy element matching on web pages (via injected JS)
- [ ] Form detection + auto-fill support
- [ ] Tab management

### Phase 5: Advanced Enrichment + OCR
- [ ] Transport-aware enrichers (combine AX + CDP + AppleScript per app)
- [ ] Numbers enricher (full spreadsheet read/write)
- [ ] Mail enricher (read/compose via AppleScript)
- [ ] OCR fallback transport (screencapture + Vision framework)
- [ ] Calendar enricher (read events, create events, availability)

## Performance Targets

| Operation | v1 (CLI) | v2 (daemon) | Target |
|-----------|----------|-------------|--------|
| list | 7ms | <2ms | ✅ |
| snapshot (cached) | 191ms | <10ms | 🎯 |
| snapshot (cold) | 191ms | <100ms | 🎯 |
| act click | 200ms | <50ms | 🎯 |
| CDP eval | 31ms | <5ms | 🎯 (persistent ws) |
| AppleScript | 159ms | <100ms | 🎯 (reuse) |
| web snapshot | N/A | <500ms | 🎯 |
| web click | N/A | <200ms | 🎯 |

## Tech Stack
- Swift + SPM (same as v1)
- Foundation `NWListener` / `NWConnection` for UDS (or raw Unix sockets)
- `NSWorkspace.shared.notificationCenter` for app events  
- `CGSessionCopyCurrentDictionary` for screen state
- Vision framework for OCR (`VNRecognizeTextRequest`)
- JSON-RPC 2.0 over UDS (simple, well-known protocol)

## File Structure
```
Sources/
  AgentView/           # CLI (thin client)
    main.swift
    Client.swift       # UDS client
    Commands/          # All CLI commands
  AgentViewDaemon/     # Daemon
    main.swift
    Server.swift       # UDS server + JSON-RPC handler
    Router.swift       # Transport router + fallback chain
    Cache.swift        # State cache + ref stability
    EventBus.swift     # Event monitoring + push
    Transports/
      AXTransport.swift
      CDPTransport.swift
      AppleScriptTransport.swift
      SafariTransport.swift
      OCRTransport.swift
    Enrichers/
      GenericEnricher.swift
      SafariEnricher.swift
      NumbersEnricher.swift
      ObsidianEnricher.swift
```
