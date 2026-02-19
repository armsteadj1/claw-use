# AgentView

**Give your AI agent eyes and hands on macOS.**

AgentView is a daemon that lets AI agents see and interact with any macOS application — browsers, native apps, even locked screens. One CLI, every app, always on.

## 30-Second Demo

```bash
# What's running?
agentview list
# → Safari, Obsidian, Notes, Calendar, Numbers...

# What's on screen?
agentview snapshot "Safari"
# → Enriched UI: 31 elements, buttons, tabs, text fields with refs (e1, e2...)

# Click something
agentview web click "Sign In"
# → ✅ clicked "Sign In", score: 100

# Fill a form
agentview web fill "email" --value "hello@example.com"
# → ✅ filled "email" field

# Take a screenshot
agentview screenshot Safari
# → 📸 1325x941 PNG saved

# All of this works with the screen locked 🔒
```

## Why AgentView?

**Your agent lives on a Mac.** It should be able to use it.

| Problem | AgentView Solution |
|---------|-------------------|
| Browser automation needs a managed browser | Uses whatever's already open (Safari, Chrome) |
| Screen locks kill your agent's eyes | Safari transport works via AppleScript — locked screen, no problem |
| One transport fails, agent loops forever | Self-healing router: AX → Safari → CDP → AppleScript, auto-fallback |
| No way to read native apps | Accessibility APIs expose Notes, Calendar, Numbers, Finder, everything |
| Slow cold-start per command | Persistent daemon with 7ms CDP eval, cached snapshots |
| Agent can't react to screen events | Event bus + webhook wakes your agent on unlock, app changes, etc. |

## What Can You Build?

### 🌐 Web Automation (Without Playwright)

Navigate, read, click, and fill on any website — through Safari, using the browser that's already there.

```bash
agentview web navigate "https://github.com/login"
agentview web snapshot
# → {pageType: "login", forms: [{fields: [email, password], submitText: "Sign in"}]}
agentview web fill "email" --value "user@example.com"
agentview web fill "password" --value "hunter2"
agentview web click "Sign in"
```

### 📸 Visual QA & Debugging

Screenshot any app and feed it to a vision model. "What does the screen look like right now?"

```bash
agentview screenshot "Xcode"
# → /tmp/agentview-screenshot-xcode-1234567.png (feed to GPT-4V, Claude, etc.)
```

### 🔓 Permission & Dialog Handler

Detect system dialogs and handle them. No more "hey human, click Allow."

```bash
agentview snapshot "SecurityAgent"
# → Password field detected
agentview act "SecurityAgent" fill --ref e1 --value "$PASSWORD"
agentview act "SecurityAgent" click --ref e2  # "OK" button
```

### 📝 Native App Control

Read and write to Notes, Calendar, Numbers — apps that have no API.

```bash
# Read your notes
agentview snapshot "Notes"
# → List of notes with titles, dates, content previews

# Read a spreadsheet
agentview snapshot "Numbers"
# → Table data with rows, columns, cell values

# Check your calendar
agentview snapshot "Calendar"
# → Today's events with times and titles
```

### 👁️ Watchdog & Triggers

Stream events and react. "Tell me when the build finishes."

```bash
agentview watch --app "Xcode" --types "value_changed"
# → JSONL stream of UI changes, piped to your agent
```

### 🔄 Self-Healing Workflows

The transport router handles failures automatically. Your agent never gets stuck.

```bash
agentview status
# → Safari: [safari: healthy, ax: healthy] 
# → Obsidian: [cdp: connected, ax: healthy]
# → Chrome: [cdp: reconnecting, ax: healthy]  ← auto-recovering
```

## Install

```bash
# Build from source
git clone https://github.com/thegreysky/agentview.git
cd agentview
swift build -c release

# Install binaries
cp .build/release/agentview ~/.local/bin/
cp .build/release/agentviewd ~/.local/bin/

# Start the daemon
agentview daemon start

# Grant Accessibility permission when prompted
# For Safari: enable Develop → Allow JavaScript from Apple Events
```

## Commands

### Core
| Command | Description |
|---------|-------------|
| `agentview list` | List all running GUI apps |
| `agentview snapshot <app>` | Enriched UI snapshot with interactive refs |
| `agentview act <app> <action> --ref <ref>` | Click, fill, focus by ref |
| `agentview pipe <app> <action> --match <text>` | Snapshot + fuzzy match + act in one call |
| `agentview screenshot <app>` | Capture window as PNG |
| `agentview status` | Daemon health, transports, screen state |
| `agentview watch [--app] [--types]` | Stream UI events as JSONL |

### Web (Safari)
| Command | Description |
|---------|-------------|
| `agentview web tabs` | List all Safari tabs |
| `agentview web navigate <url>` | Open URL (or switch to existing tab) |
| `agentview web snapshot` | Semantic page analysis (type, forms, links, content) |
| `agentview web click <match>` | Fuzzy click on page element |
| `agentview web fill <match> --value <val>` | Fuzzy fill form field |
| `agentview web extract` | Page content as clean markdown |
| `agentview web tab <match>` | Switch tab by fuzzy title/URL |

### Daemon
| Command | Description |
|---------|-------------|
| `agentview daemon start` | Start the daemon |
| `agentview daemon stop` | Stop the daemon |
| `agentview daemon status` | Check if running |

## How It Works (High Level)

AgentView runs a persistent daemon (`agentviewd`) that maintains connections to every app on your Mac through multiple transport layers:

- **Accessibility APIs** — the richest UI data (roles, labels, values, actions)
- **Chrome DevTools Protocol** — persistent WebSocket to Electron apps (7ms eval!)
- **AppleScript** — data access + Safari JavaScript injection (works locked 🔒)
- **Screenshots** — CGWindowListCreateImage for visual capture

The **self-healing router** picks the best transport per app and auto-falls back on failure. A **snapshot cache** keeps refs stable across calls (`e1` stays `e1`). An **event bus** watches for app lifecycle, UI changes, and screen state — and can wake your agent via webhook.

→ Deep dive: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

## For Agent Developers

AgentView is designed to be called from AI agent tool loops. The JSON output is structured for LLM consumption:

- **Refs** (`e1`, `e2`, `w1`) are stable handles to UI elements
- **Fuzzy matching** (`--match "Sign In"`) means your agent doesn't need exact selectors
- **Semantic page types** (`login`, `search`, `article`, `table`) let your agent understand what it's looking at
- **`pipe` command** combines snapshot + match + act in one round-trip (~200ms total)
- **JSONL events** can drive reactive agent behavior (watch for changes, not poll)

### Example: OpenClaw Skill

```yaml
# agentview skill for OpenClaw agents
name: agentview
description: See and interact with any macOS app via AgentView CLI
```

```markdown
## Available Commands
- `agentview list` — see what's running
- `agentview snapshot <app>` — get UI state with refs
- `agentview act <app> click --ref e3` — click element e3
- `agentview web navigate <url>` — open a URL in Safari
- `agentview web fill "email" --value "..."` — fill a form field
- `agentview screenshot <app>` — capture window screenshot

## Tips
- Use `pipe` for one-shot interactions (faster than snapshot + act)
- Check `status` before UI operations — if screen is locked, use web commands
- Refs are stable within a session — `e1` stays `e1` until the element disappears
```

## Roadmap

- [x] Phase 1: Daemon + UDS + persistent CDP + screen state
- [x] Phase 2: Self-healing router + transport fallback
- [x] Phase 3: Snapshot cache + event bus + watch stream  
- [x] Phase 4: Safari browser control + semantic page analysis
- [ ] Phase 5: Transport-aware enrichers + OCR fallback
- [ ] Chrome DevTools integration (remote debugging)
- [ ] Multi-display support
- [ ] Agent skill marketplace integration

## License

MIT
