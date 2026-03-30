# Quickstart

You installed cua. Here's what to do in the next 5 minutes.

---

## 1. Grant Permissions

cua needs two permissions to work fully.

### Accessibility (required for native apps)

1. Open **System Settings → Privacy & Security → Accessibility**
2. Add `cua` (or your terminal app if running from terminal)
3. Toggle it on

Without this, `cua snapshot` on native apps returns empty or partial trees.

### Safari JavaScript (required for web commands)

1. Open **Safari → Develop → Allow JavaScript from Apple Events**

If you don't see the Develop menu: **Safari → Settings → Advanced → Show Develop menu in menu bar**

---

## 2. Start the Daemon

```bash
cua daemon start
# → {"status":"started","pid":12345}
```

The daemon runs in the background and persists across terminal sessions. You only need to do this once (or after a reboot — set it up as a login item to auto-start).

Check it's healthy:

```bash
cua status
# → daemon: running | screen: unlocked | CDP: 2 connections
```

---

## 3. Five Commands to Try Right Now

### See what's running

```bash
cua list
```

You'll see every GUI app currently running — Safari, Notes, Obsidian, whatever's open.

### Snapshot an app

```bash
cua snapshot "Notes"
```

You'll get a structured view of the UI: every button, text field, list item — with element refs (`e1`, `e2`...) you can use to interact.

### Click something

```bash
cua pipe "Notes" click --match "New Note"
```

This finds the element with text matching "New Note" and clicks it. One call.

### Automate Safari

```bash
cua web navigate "https://example.com"
cua web snapshot
```

Full web automation — reads the page as structured data, not HTML soup.

### Take a screenshot

```bash
cua screenshot "Safari"
# → /tmp/cua-screenshot-Safari-1234567.png
```

---

## 4. Output Formats

By default, output is **compact** — optimized for agent token budgets. Small, structured, readable.

```bash
# Compact (default) — best for agents
cua snapshot "Safari"

# Pretty JSON — good for debugging
cua snapshot "Safari" --format json --pretty
```

---

## 5. If Something Doesn't Work

### "Empty snapshot" or missing elements

- Accessibility permission isn't granted — check System Settings → Privacy & Security → Accessibility
- For Electron apps (VS Code, Obsidian): try `cua restore Obsidian --launch` then snapshot again
- Some apps need a moment to load — retry after a second

### Safari web commands fail

- Enable: Safari → Develop → Allow JavaScript from Apple Events
- Make sure a tab is active in Safari
- Check `cua status` to see if Safari transport is connected

### Daemon won't start

```bash
cua daemon stop   # force stop any stale process
cua daemon start  # try again
cua status        # check health
```

### Transport not working

```bash
cua status
# Shows: daemon health, screen state, CDP connections per app
```

If screen is locked, AX transport is unavailable for most apps. Use `cua web` commands — they work via AppleScript and don't need a display.

---

## Next Steps

- [AGENT-GUIDE.md](AGENT-GUIDE.md) — wire cua into an AI agent
- [INSTALL.md](INSTALL.md) — update cua, alternative install methods
- [ARCHITECTURE.md](ARCHITECTURE.md) — how the daemon and transports work
