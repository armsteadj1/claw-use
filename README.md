# AgentView

**Give your AI agent eyes and hands on macOS.**

AgentView is a persistent daemon that lets agents interact with any running macOS application — browsers, native apps, even locked screens. One CLI, every app, always on.

## The Numbers

We benchmarked AgentView against the tools agents use today — browser automation (Playwright/CDP snapshots), AppleScript via `exec`, and HTTP fetch. Same page, same tasks, real measurements.

### Speed

| Task | Today | AgentView | Improvement |
|------|-------|-----------|-------------|
| List running apps | 190ms (AppleScript) | **27ms** | 7x faster |
| Web page snapshot | ~1,200ms (browser tool) | **235ms** | 5x faster |
| Click an element | snapshot + act (2 calls) | **968ms** (1 call via `pipe`) | Single round-trip |
| Screenshot | ~500ms (browser) | **109ms** | 4.5x faster |
| Text extraction | 300ms (web fetch) | **251ms** | Comparable |

### Token Cost

Same page (IANA Example Domains), same information:

| Format | Bytes | Relative |
|--------|-------|----------|
| Browser tool (ARIA tree) | 3,318 | 5.7x more |
| AgentView JSON | 2,526 | 4.4x more |
| **AgentView compact** | **577** | **1x** |

The compact snapshot contains everything an agent needs — links with URLs, headings, page type, word count. The browser tool returns the entire DOM tree including footer cells, ARIA landmarks, and nested role annotations.

At 10 snapshots per task, that's **~27,000 bytes saved per task** — real money at LLM token prices.

### Tool Calls Per Workflow

**"Read a page and click something"**
- Today: `snapshot` → parse → `act click` = **3 tool calls**, ~4,000+ bytes
- AgentView: `pipe safari click --match "Sign in"` = **1 tool call**, ~50 bytes back

**"Fill a login form"**
- Today: `snapshot` → `fill email` → `fill password` → `click submit` = **4 calls**
- AgentView: 3× `pipe` commands = **3 calls**, each self-contained (no snapshot step needed)

Fewer tool calls = fewer LLM round-trips = faster completion = lower cost.

## What You Can't Do Today

| Capability | Current Tools | AgentView |
|-----------|---------------|-----------|
| 🔒 Locked screen | Dead — browser tools need a display | Safari transport works via AppleScript |
| 📱 Native apps (Notes, Calendar, Numbers) | No tool covers this | Full AX UI tree with refs and actions |
| 👁️ Event-driven wake | Poll in a loop, burn tokens | **Sentinels** push events to your agent |
| 🔄 Transport failure | Retry the same broken path | Auto-fallback: AX → Safari → CDP → AppleScript |
| ⚡ One-shot interactions | Snapshot, parse, then act (3 steps) | `pipe` = snapshot + match + act in 1 call |

## 30-Second Demo

```bash
# What's running?
agentview list
# → Safari, Obsidian, Notes, Calendar, Numbers...

# What's on screen?
agentview snapshot "Safari"
# → Enriched UI: 31 elements, buttons, tabs, text fields with refs (e1, e2...)

agentview pipe safari click --match "Sign in"
# ✅ clicked "Sign in" (score: 100)

# All of this works with the screen locked 🔒
```

## Sentinels

AgentView doesn't just respond to commands — it watches.

The **event bus** monitors app lifecycle, UI changes, screen state, and foreground switches. When something happens, it wakes your agent via webhook instead of your agent polling "did anything change?"

```bash
# Stream events as JSONL
agentview watch --app Safari --types value_changed,title_changed

# Configure webhooks — your agent gets called when something needs attention:
# - A build finishes in Xcode
# - A dialog pops up asking for permission
# - The screen unlocks and apps are visible again
# - A file changes in Finder
```

Think of Sentinels as your agent's peripheral vision. Instead of burning tokens on polling loops, the daemon tells your agent when to look.

Screenshot any app and feed it to a vision model. "What does the screen look like right now?"

```bash
agentview screenshot "Xcode"
# → /tmp/agentview-screenshot-xcode-1234567.png (feed to GPT-4V, Claude, etc.)
```

### 🔓 Permission & Dialog Handler

### Output
Default output is **compact** — optimized for agent token budgets. Use `--format json` when you need structured data, `--pretty` for human-readable JSON.

## How It Works

AgentView runs a persistent daemon (`agentviewd`) that maintains connections to every app through four transport layers:

- **Accessibility (AX)** — richest data: roles, labels, values, actions for any native app
- **Chrome DevTools Protocol** — persistent WebSocket to Electron apps, 7ms eval
- **AppleScript** — app scripting + Safari JS injection (works on locked screens 🔒)
- **Screenshots** — CGWindowListCreateImage for visual capture

The **self-healing router** picks the best transport per app and auto-falls back on failure. Snapshots are cached with stable refs. The event bus watches everything.

→ Deep dive: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

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
