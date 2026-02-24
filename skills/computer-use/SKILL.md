---
name: computer-use
description: Control any macOS application using cua (claw-use) — snapshot UI state, click/fill/toggle elements, automate Safari, take screenshots, and monitor processes. Use when you need to interact with desktop apps, read screen content, fill forms, navigate websites in Safari, or track background processes.
---

# Computer Use with cua

`cua` gives you structured access to any running macOS app via Accessibility APIs. Instead of screenshots + vision models, you get actionable JSON with element refs you can click, fill, and read — fast, cheap, reliable.

## Prerequisites

- `cua` CLI installed, `cuad` daemon running (`cua daemon start`)
- macOS Accessibility permission granted (System Settings → Privacy & Security → Accessibility)
- For Safari web commands: Safari → Develop → Allow Remote Automation

## Setting Up Remote Access (Agent → Human's Mac)

If you need to see and control your human's Mac remotely, run the pairing ceremony:

### On your machine (agent):
```bash
cua remote accept
```

This outputs a command. Send it to your human via your messaging channel:
> "Hey — run this on your laptop so I can help you: `cua remote pair 100.x.x.x wren-7x4k`"

### Human runs on their Mac:
```bash
cua remote pair 100.x.x.x wren-7x4k
```

### You'll see:
```
✅ Paired with james-laptop. Try: cua --remote james-laptop status
```

### After pairing:
```bash
cua --remote james-laptop status
cua --remote james-laptop list
cua --remote james-laptop snapshot Safari
```

**On Tailscale:** `cua remote accept` auto-detects your Tailscale IP and binds only to it. No firewall rules needed — only machines on your Tailscale network can reach the pairing port.

---

## Core Workflow

The fundamental loop for any task:

```
1. cua list                          → find the app
2. cua snapshot "<app>"              → see what's on screen
3. cua act "<app>" click --ref e4    → interact with elements
4. cua snapshot "<app>"              → verify result
```

## Quick Reference

### Discovery

```bash
# List all running GUI apps
cua list

# Full system status (daemon, screen state, CDP connections)
cua status
```

### Snapshots — Read Any App's UI

```bash
# Compact format (default) — best for agents
cua snapshot "Chrome"

# JSON format for programmatic use
cua snapshot "Chrome" --format json --pretty

# Paginate large UIs (continue from element ref)
cua snapshot "Chrome" --after e50 --limit 50

# Control tree depth
cua snapshot "Chrome" --depth 10
```

**Output** is a structured tree with element refs (`e0`, `e1`, `e4`...), roles, labels, and values. Use these refs with `act`.

### Actions — Interact with Elements

```bash
# Click a button/link/element
cua act "Chrome" click --ref e4

# Fill a text field
cua act "Chrome" fill --ref e7 --value "search query"

# Clear a field
cua act "Chrome" clear --ref e7

# Toggle a checkbox/switch
cua act "Chrome" toggle --ref e12

# Select from a dropdown
cua act "Chrome" select --ref e9 --value "Option 2"

# Focus an element
cua act "Chrome" focus --ref e3
```

### Pipe — Snapshot + Match + Act in One Call (~200ms)

When you know what you're looking for by label/text, skip the snapshot step:

```bash
# Click by fuzzy text match
cua pipe "Chrome" click --match "Sign In"

# Fill by fuzzy match
cua pipe "Chrome" fill --match "Email" --value "user@example.com"

# Read an element's value
cua pipe "Chrome" read --match "Total"
```

`pipe` is the fastest path — one round trip instead of two.

### Screenshots

```bash
# Capture window screenshot
cua screenshot "Chrome"
# → saves to /tmp/cua-screenshot-Chrome-<timestamp>.png

# Custom output path
cua screenshot "Chrome" --output /tmp/my-screenshot.png
```

### App Management

```bash
# Open/launch an app
cua open "Safari"
cua open "Safari" --url "https://example.com" --wait

# Bring app to front
cua focus "Chrome"

# Restore Electron apps (e.g., Obsidian after reboot)
cua restore Obsidian --launch
```

## Safari Web Automation

Full web automation without a browser driver:

```bash
# List open tabs
cua web tabs

# Switch tab by fuzzy match
cua web tab "GitHub"

# Navigate to URL
cua web navigate "https://example.com"

# Semantic snapshot of page content
cua web snapshot

# Paginate web snapshots
cua web snapshot --after 15 --limit 15

# Extract page as markdown
cua web extract

# Paginate extraction
cua web extract --after 2000 --limit 2000

# Click by text/label
cua web click "Submit"

# Fill a form field
cua web fill "Email" --value "user@example.com"
```

### Web Workflow Example

```bash
cua open Safari --url "https://github.com/login" --wait
cua web fill "Username" --value "myuser"
cua web fill "Password" --value "mypass"
cua web click "Sign in"
cua web snapshot  # verify logged in
```

## Process Monitoring

Track long-running processes (e.g., Claude Code agents) with automatic notifications:

### One-Time Webhook Setup

```bash
cua events subscribe \
  --filter "process.exit,process.error" \
  --webhook "http://localhost:18789/hooks/wake" \
  --webhook-token "$(jq -r '.hooks.wake.token' ~/.openclaw/openclaw.json)" \
  --webhook-meta '{"mode":"now","text":"🔔 Process finished"}' \
  --cooldown 10 \
  --max-wakes 30
```

### Track Processes

```bash
# Register a process for dashboard tracking
cua process group add $PID --label "my-task"

# Attach watcher (--stream required for webhooks)
cua process watch $PID --stream --log /tmp/task.log &

# Dashboard
cua process group status

# Clean up completed
cua process group clear
```

### Event Management

```bash
cua events list          # Active subscriptions
cua events recent        # Debug: recent events
cua events unsubscribe <id>  # Remove subscription
```

## Raw AX Tree (Advanced)

For debugging or building app-specific enrichers:

```bash
cua raw "Chrome" --pretty
```

## Tips

1. **Use `pipe` when you can** — it's one call vs two (snapshot + act). ~200ms total.
2. **Compact format is best for agents** — less tokens, same info. JSON for scripts.
3. **Paginate large UIs** — `--after e50` continues where you left off.
4. **Fuzzy matching is forgiving** — "sign in", "Sign In", "signin" all work in pipe/web.
5. **Always verify** — snapshot after acting to confirm the action took effect.
6. **`cua status`** tells you everything — daemon health, screen state, CDP connections.
7. **Safari web commands work alongside AX** — use `web snapshot` for page content, regular `snapshot Safari` for the browser chrome/UI.
