# cua

Your agent is blind without this.

cua gives AI agents eyes and hands on macOS — native apps, browsers, locked screens. One daemon, one CLI, every app.

```bash
cua list
# → Safari, Notes, Obsidian, Calendar...

cua snapshot "Notes"
# → 14 elements: buttons, text fields, list rows — all with refs (e1, e2...)

cua pipe safari click --match "Sign In"
# ✅ clicked "Sign In" (score: 100)

# Works with the screen locked 🔒
```

---

## The Problem

Agents running on macOS hit a wall fast.

They can't open Notes and read your to-dos. They can't fill a form in a native app. If the screen locks, everything dies. And when they do have browser access, they're making 3–5 tool calls where one would do — snapshot, parse, act, verify, check again.

Every tool call is a round-trip to the LLM. Slow. Expensive. Fragile.

**The specific gaps:**

- Native apps (Notes, Calendar, Numbers, Xcode) — no tool covers them
- Locked screen — browser automation needs a display; dies silently
- One-shot interactions — always snapshot + parse + act instead of a single command
- Transport failure — no fallback, just a crashed task

---

## The Fix

cua is a persistent daemon + CLI that lives on your Mac and gives your agent full access to everything running.

- **See any native app** — full UI tree from macOS Accessibility APIs
- **Interact with elements** — click, fill, toggle, select by ref or fuzzy match
- **Locked screen? Still works** — Safari and AppleScript transports don't need a display
- **One-shot `pipe` command** — snapshot + match + act in a single CLI call (~200ms)
- **Token-efficient output** — compact format is 5x smaller than browser tool ARIA trees

---

## Quickstart

```bash
# Install
brew install armsteadj1/tap/cua

# Start the daemon
cua daemon start

# Grant Accessibility permission when prompted
# For Safari: Safari → Develop → Allow JavaScript from Apple Events

# Try it
cua list
cua snapshot "Safari"
cua pipe safari click --match "Sign In"
```

→ Full setup guide: [docs/QUICKSTART.md](docs/QUICKSTART.md)

---

## Key Concepts

| Term | Definition |
|------|------------|
| `cuad` | The background daemon. Starts once, stays running. Maintains persistent connections to all apps. Your CLI commands talk to it over a Unix socket (`~/.cua/sock`). |
| `cua` | The CLI client — what you (or your agent) runs. A thin JSON-RPC wrapper over a socket call to cuad. |
| ref | A stable handle to a UI element (e.g., `e4`, `w2`). Stays stable until the element disappears. Use refs with `act` to interact without re-scanning. |
| snapshot | A compact read of an app's current UI state — structured, ref-annotated, token-efficient. Cached for ~5 seconds. |
| pipe | One-shot command: snapshot + fuzzy match + act in a single CLI call. The fastest path for any known interaction. |
| transport | How cuad talks to a specific app. Each transport implements: can it handle this app? How healthy is it? Execute this action. |
| AX | macOS Accessibility API. Richest data source — full UI tree with roles, labels, values, actions. Works for any native app with Accessibility permission. |
| CDP | Chrome DevTools Protocol. Used for Electron apps (VS Code, Obsidian, Cursor). Persistent WebSocket, 7ms eval latency. |
| AppleScript | Used for app scripting and data-level operations. Works on locked screens. App-specific scripts for Notes, Safari, Calendar, Numbers. |

---

## Use Cases

### 1. Read your inbox — no email API required

```bash
cua snapshot "Mail"
# → inbox: 12 unread, subject lines, sender names, all with refs

cua act "Mail" click --ref e8   # open an email
cua snapshot "Mail"             # read the body
```

No OAuth. No API key. Mail is just another app.

---

### 2. Fill a form in a native app

```bash
cua pipe "Contacts" fill --match "First Name" --value "Jane"
cua pipe "Contacts" fill --match "Last Name" --value "Smith"
cua pipe "Contacts" click --match "Done"
```

Three calls, form filled. No web scraping, no browser driver.

---

### 3. Automate Safari with the screen locked

```bash
cua web navigate "https://github.com/login"
cua web fill "Username" --value "myuser"
cua web fill "Password" --value "mypass"
cua web click "Sign in"
```

Screen locked? Doesn't matter. Safari transport uses AppleScript injection — no display required.

---

### 4. Screenshot any app and feed it to a vision model

```bash
cua screenshot "Xcode"
# → /tmp/cua-screenshot-xcode-1234567.png
```

Pipe the path to GPT-4V, Claude, or any vision model. Visual verification without a human.

---

### 5. Assert what's actually on screen — in tests or agent loops

```bash
cua assert "Chrome" --match "Welcome, Jane"
# → exit 0 if found, exit 1 if not
```

Tests that check what's actually rendered — not mocked responses, not DOM state.

---

## Talking to an Agent

### Option 1: OpenClaw Skill

Drop this in your agent's skills directory:

```yaml
name: computer-use
description: See and interact with any macOS app — snapshot UI state, click elements, fill forms, take screenshots, automate Safari even with screen locked.
```

```markdown
## Core Workflow
1. `cua list` — find the running app
2. `cua snapshot "<app>"` — see what's on screen (returns refs)
3. `cua act "<app>" click --ref e4` — click element e4
4. `cua snapshot "<app>"` — verify the result

## Key Commands
- `cua pipe "<app>" click --match "text"` — find + click in one call
- `cua pipe "<app>" fill --match "field" --value "..."` — find + fill in one call
- `cua web navigate "https://..."` — Safari navigation
- `cua web click "text"` — click web element by label
- `cua web fill "field" --value "..."` — fill web form field
- `cua screenshot "<app>"` — capture window
- `cua status` — daemon health + screen state

## Tips
- Use `pipe` when you know the element text — one call instead of two
- Refs are stable within a session — `e1` stays `e1` until element disappears
- Screen locked? Use `cua web` commands — they work via AppleScript
- Verify with a snapshot after acting to confirm the action took effect
```

→ Full skill: [skills/computer-use/SKILL.md](skills/computer-use/SKILL.md)

---

### Option 2: Tool Loop

```python
import subprocess

def cua(args):
    result = subprocess.run(["cua"] + args, capture_output=True, text=True)
    return result.stdout

# snapshot → decide → act → repeat
while True:
    state = cua(["snapshot", "Notes"])
    action = llm(state, user_goal)   # your LLM call

    if action["type"] == "click":
        cua(["act", "Notes", "click", "--ref", action["ref"]])
    elif action["type"] == "fill":
        cua(["act", "Notes", "fill", "--ref", action["ref"], "--value", action["value"]])
    elif action["type"] == "done":
        break
```

→ Full integration guide: [docs/AGENT-GUIDE.md](docs/AGENT-GUIDE.md)

---

## How It Works

cuad runs as a persistent background daemon. CLI commands are thin JSON-RPC clients over a Unix socket (`~/.cua/sock`). The daemon picks the best transport per app, falls back automatically on failure, and caches snapshots to avoid redundant reads.

```
Your agent
  └── cua <cmd>         (thin CLI client)
        └── ~/.cua/sock  (Unix socket)
              └── cuad   (daemon)
                    ├── AX Transport      (native apps — richest data)
                    ├── CDP Transport     (Electron: VS Code, Obsidian)
                    ├── AppleScript       (locked screen, scripting)
                    └── Safari Transport  (web + locked screen)
```

→ Deep dive: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

---

## Performance

**Speed vs. current tools (same tasks, real measurements):**

| Task | Today | cua | Improvement |
|------|-------|-----|-------------|
| List running apps | 190ms (AppleScript) | **27ms** | 7x faster |
| Web page snapshot | ~1,200ms (browser tool) | **235ms** | 5x faster |
| Click an element | snapshot + act (2 calls) | **968ms** (1 call via `pipe`) | Single round-trip |
| Screenshot | ~500ms (browser) | **109ms** | 4.5x faster |

**Token cost (same page, IANA Example Domains):**

| Format | Bytes | Relative |
|--------|-------|----------|
| Browser tool (ARIA tree) | 3,318 | 5.7x more |
| cua JSON | 2,526 | 4.4x more |
| **cua compact** | **577** | **1x** |

**So what does this mean for your agent?**

Fewer tool calls = fewer LLM round-trips = faster + cheaper. `pipe` cuts per-interaction calls from 3 to 1. Compact format saves ~27,000 bytes per task at 10 snapshots. Real money at LLM token prices.

---

## Install

### Homebrew (recommended)

```bash
brew install armsteadj1/tap/cua
```

### Shell script

```bash
curl -fsSL https://raw.githubusercontent.com/armsteadj1/claw-use/main/install.sh | sh
```

### Build from source

```bash
git clone https://github.com/armsteadj1/claw-use.git
cd claw-use
swift build -c release
cp .build/release/cua .build/release/cuad ~/.local/bin/
```

### Update

```bash
cua update
```

Or via Homebrew:

```bash
brew upgrade armsteadj1/tap/cua
```

→ Full install guide (all methods, permissions, PATH setup): [docs/INSTALL.md](docs/INSTALL.md)

---

## Docs

| File | Description |
|------|-------------|
| [docs/QUICKSTART.md](docs/QUICKSTART.md) | First 5 minutes — permissions, first commands, troubleshooting |
| [docs/INSTALL.md](docs/INSTALL.md) | All install methods, update instructions, PATH setup |
| [docs/AGENT-GUIDE.md](docs/AGENT-GUIDE.md) | Integrating cua into an AI agent — tool loops, best practices |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How the daemon, transports, and caching work |
| [skills/computer-use/SKILL.md](skills/computer-use/SKILL.md) | OpenClaw computer-use skill |

---

## License

MIT
