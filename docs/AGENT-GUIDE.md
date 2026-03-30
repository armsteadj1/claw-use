# Agent Integration Guide

How to wire cua into an AI agent — loops, refs, error handling, best practices.

---

## The Core Loop

Every cua-based agent does the same thing:

```
1. snapshot — read the current UI state
2. decide — pass state to LLM, get action
3. act — execute the action
4. verify — snapshot again to confirm
5. repeat or done
```

In practice:

```python
import subprocess, json

def cua(args):
    result = subprocess.run(["cua"] + args, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"cua error: {result.stderr}")
    return result.stdout.strip()

def agent_loop(app, goal):
    for _ in range(20):  # max iterations
        state = cua(["snapshot", app])
        action = llm_decide(state, goal)

        if action["type"] == "done":
            return action.get("result")
        elif action["type"] == "click":
            cua(["act", app, "click", "--ref", action["ref"]])
        elif action["type"] == "fill":
            cua(["act", app, "fill", "--ref", action["ref"], "--value", action["value"]])
        elif action["type"] == "pipe":
            cua(["pipe", app, action["action"], "--match", action["match"],
                 "--value", action.get("value", "")])
```

---

## Using Refs

Refs (`e1`, `e2`, `w1`) are stable handles to UI elements. They come from `cua snapshot` and stay valid until the element disappears from the UI.

**Getting refs:**

```bash
cua snapshot "Notes"
# Output includes refs for every element:
# e1 [window] Notes
#   e2 [toolbar]
#     e3 [button] New Note
#     e4 [search-field] Search
#   e5 [list]
#     e6 [cell] Shopping list
#     e7 [cell] Meeting notes
```

**Using refs:**

```bash
cua act "Notes" click --ref e3      # click "New Note" button
cua act "Notes" fill --ref e4 --value "groceries"  # type in search
cua act "Notes" click --ref e6      # open "Shopping list"
```

**Ref safety rules:**

1. Refs are only valid after the snapshot that produced them
2. After any action, some refs may become stale (if the UI changed)
3. For anything that changes the UI (click, fill), snapshot again before using new refs
4. For non-destructive reads, refs stay stable across multiple reads of the same state

---

## Using `pipe` for One-Shot Interactions

When you know what you're looking for by text, skip the snapshot step entirely:

```bash
# Instead of:
cua snapshot "Safari"     # → get refs
cua act "Safari" click --ref e12   # click "Sign In"

# Do this:
cua pipe "Safari" click --match "Sign In"
# → snapshots internally, finds best match, clicks — one call
```

`pipe` is ideal when:
- Your LLM knows the element label but not the ref
- You're running a known workflow (login, form fill, navigation)
- You want to minimize round-trips

`pipe` output:
```json
{"status": "ok", "matched": "Sign In", "score": 100, "ref": "e12"}
```

If nothing matches above threshold, it returns an error instead of clicking the wrong thing.

---

## Web Automation

For Safari-based web automation, use `cua web` commands. These work even with the screen locked.

```bash
# Navigate
cua web navigate "https://github.com"

# Read page content
cua web snapshot          # structured semantic snapshot
cua web extract           # page as markdown (good for reading content)

# Interact
cua web click "Sign in"
cua web fill "Username" --value "myuser"
cua web fill "Password" --value "mypass"

# Tabs
cua web tabs              # list all open tabs
cua web tab "GitHub"      # switch to tab matching "GitHub"
```

**Web vs. AX:**
- `cua web snapshot` reads the page content (semantic, good for agents)
- `cua snapshot "Safari"` reads the browser chrome (address bar, tabs, toolbar)
- Use both when you need full context

---

## Handling Errors

### Transport failure

```bash
cua snapshot "Obsidian"
# Error: transport unavailable
```

If AX fails, try `restore` then retry:

```bash
cua restore Obsidian --launch
sleep 2
cua snapshot "Obsidian"
```

### Screen locked

```bash
cua status
# → screen: locked
```

When locked, AX is unavailable for most apps. Fall back to web commands:

```python
status = json.loads(cua(["status", "--format", "json"]))
if status.get("screen") == "locked":
    # Use web commands only
    cua(["web", "navigate", url])
else:
    # Full AX available
    cua(["snapshot", app])
```

### Missing ref

If a ref no longer exists (element disappeared), `act` returns an error. Always snapshot after actions that change the UI before using new refs.

### Daemon not running

cua auto-starts the daemon on first call. If it fails:

```bash
cua daemon start
cua status
```

---

## Pagination for Large UIs

Some apps have hundreds of elements. Paginate to stay within token limits:

```bash
# Get first 50 elements
cua snapshot "Xcode" --limit 50

# Continue from e50
cua snapshot "Xcode" --after e50 --limit 50
```

In your agent loop, check for `next_ref` in the JSON output:

```python
result = json.loads(cua(["snapshot", "Xcode", "--format", "json"]))
while result.get("next_ref"):
    result = json.loads(cua(["snapshot", "Xcode", "--after", result["next_ref"], "--format", "json"]))
    # ... process elements
```

---

## OpenClaw Skill

Full SKILL.md content for OpenClaw agents:

```yaml
---
name: computer-use
description: Control any macOS application using cua (claw-use) — snapshot UI state, click/fill/toggle elements, automate Safari, take screenshots, and monitor processes. Use when you need to interact with desktop apps, read screen content, fill forms, navigate websites in Safari, or track background processes.
---
```

See the full skill at [skills/computer-use/SKILL.md](../skills/computer-use/SKILL.md).

---

## Best Practices

**1. Use compact format** — it's the default and the right choice for agents. 5x fewer tokens than JSON, same information.

```bash
cua snapshot "Notes"           # compact (default)
cua snapshot "Notes" --format json --pretty  # only when debugging
```

**2. Check status before UI operations** — especially in long-running agents.

```bash
cua status
# Tells you: daemon health, screen locked/unlocked, CDP connections
```

**3. Use `pipe` for known interactions** — saves one round-trip per interaction.

```bash
# Good for known workflows
cua pipe "Safari" click --match "Accept"
cua pipe "Safari" fill --match "Email" --value "user@example.com"
```

**4. Verify after actions** — don't assume the click worked.

```bash
cua act "Notes" click --ref e3
cua snapshot "Notes"   # confirm the UI changed as expected
```

**5. Respect ref stability** — refs survive reads but not UI changes. After any action that modifies the UI (click, fill, navigation), get fresh refs.

**6. Use `assert` for checkpoints** — add assertions in agent loops to catch unexpected states early.

```bash
cua assert "Safari" --match "Logged in"
# exit 0 = found, exit 1 = not found
```

**7. Use `wait` for async operations** — when clicking triggers a loading state.

```bash
cua act "Safari" click --ref e5    # click "Load"
cua wait "Safari" --match "Results" --timeout 10  # wait up to 10s
```

---

## Example: Full Login Flow

```python
import subprocess, json

def cua(args):
    r = subprocess.run(["cua"] + args, capture_output=True, text=True)
    return r.stdout.strip()

# Navigate to login page
cua(["web", "navigate", "https://app.example.com/login"])

# Fill credentials
cua(["web", "fill", "Email", "--value", "user@example.com"])
cua(["web", "fill", "Password", "--value", "secret"])
cua(["web", "click", "Sign in"])

# Wait for dashboard
result = subprocess.run(
    ["cua", "wait", "--app", "Safari", "--match", "Dashboard", "--timeout", "10"],
    capture_output=True
)
if result.returncode != 0:
    raise RuntimeError("Login failed — Dashboard not found")

# Read dashboard state
state = cua(["web", "snapshot"])
print("Logged in. Dashboard state:", state[:200])
```
