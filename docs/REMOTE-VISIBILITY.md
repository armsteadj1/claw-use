# Remote Visibility: Giving a Remote Agent Eyes on a Local Mac

## The Problem

`cua` runs on the local machine it observes — it needs direct access to macOS Accessibility APIs, the window server, and local Unix domain sockets. But the agent *orchestrating* work (e.g., Hedwig running on a Mac Mini) lives on a different machine.

Goal: give the remote agent meaningful visibility into what's happening on the user's laptop, without building a custom transport layer or punching holes in firewalls.

---

## Two Core Approaches

### Approach A: Tailscale + SSH (Recommended — best for active agent control)

Tailscale creates a private WireGuard mesh between your machines. SSH over Tailscale gives the remote agent a secure, authenticated command channel with no open ports on the public internet.

**Setup:**

1. Install Tailscale on both machines and sign in to the same account:
   ```bash
   brew install tailscale
   tailscale up
   ```

2. Set up SSH key authentication on the laptop. Create a dedicated key for the agent:
   ```bash
   # On the Mac Mini (agent machine)
   ssh-keygen -t ed25519 -C "hedwig-agent" -f ~/.ssh/hedwig_agent_key
   ```

3. Add the public key to `~/.ssh/authorized_keys` on the laptop, **restricted to only run `cua`**:
   ```
   command="/usr/local/bin/cua $SSH_ORIGINAL_COMMAND",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAA... hedwig-agent
   ```
   This means the remote agent can SSH in, but can *only* run `cua` — nothing else.

4. The remote agent now runs commands like:
   ```bash
   ssh james-laptop cua status
   ssh james-laptop cua list
   ssh james-laptop cua snapshot Safari
   ssh james-laptop cua snapshot Xcode --format compact
   ```

5. **Optional: expose the Unix domain socket via socat over SSH**

   For direct daemon access without going through the CLI each time:
   ```bash
   # On laptop: forward UDS over SSH
   ssh -R /tmp/cua-remote.sock:/tmp/cuad.sock james-laptop -N

   # On Mac Mini: talk directly to the daemon
   echo '{"jsonrpc":"2.0","method":"status","id":1}' | socat - UNIX-CONNECT:/tmp/cua-remote.sock
   ```

**Why this is recommended:**
- No open ports on the public internet (Tailscale handles NAT traversal)
- SSH key with `command=` restriction means a compromised agent key can only run `cua`
- Fast: each `ssh` round-trip is ~20-50ms over Tailscale LAN
- Works even when the laptop screen is locked (cua's AppleScript transport still works)

---

### Approach B: Log Shipping (Good for async monitoring)

The daemon maintains an internal event bus. A future log-write mode would append events to a file that syncs automatically via cloud storage.

**How it would work:**

1. Daemon writes to `~/.cua/remote.jsonl` (one JSON event per line):
   ```json
   {"timestamp":"2026-02-23T10:15:00Z","type":"app.launched","app":"Xcode","pid":12345}
   {"timestamp":"2026-02-23T10:15:01Z","type":"screen.unlock","details":{}}
   ```

2. Sync the file via iCloud Drive, Dropbox, or Resilio Sync

3. Remote agent tails or polls the file:
   ```python
   # Tail the remote event log
   with open("/path/to/icloud/remote.jsonl") as f:
       f.seek(0, 2)  # seek to end
       while True:
           line = f.readline()
           if line:
               event = json.loads(line)
               handle_event(event)
           else:
               time.sleep(1)
   ```

**Characteristics:**
- Low-latency via iCloud sync (~5-30s lag, Resilio is faster at ~1-5s)
- No SSH required — purely file-based
- Read-only: agent can observe but not act (pair with Approach A for actions)
- Suitable for "ambient awareness" use cases (was the screen locked? did Xcode launch?)

> **Note:** The `--log-remote` flag for daemon log writing is a suggested future feature. Current `cua` does not write to a remote JSONL file automatically.

---

## Privacy Levels

Define how much information you're comfortable exposing to a remote agent. Use the lowest level that meets your needs.

| Level | Name | What's visible | Safe for remote? |
|-------|------|----------------|-----------------|
| 0 | Status | App names, screen lock state, frontmost app | Always safe |
| 1 | Events | App launches/quits, focus changes, screen unlock | Safe |
| 2 | Structure | UI element labels/roles, window titles, button names (NOT field values) | Review app list |
| 3 | Full | Everything including field values, page content, screenshots | Requires explicit consent per app |

**Default recommendation:** Run the remote agent at Level 0-1. Elevate to Level 2 only for specific apps you've reviewed (Terminal, Xcode, Slack). Never use Level 3 for apps that handle passwords, banking, or private messages.

---

## Sensitive Data Scrubbing

Even at Level 2, some information should never leave the local machine.

**Recommended scrubbing rules:**

1. **Password fields** — Never expose values from AX elements where `role == "AXSecureTextField"`. The element can appear in structure output (so the agent knows a password field exists), but its value must be empty or redacted.

2. **App blocklist** — Never snapshot these apps at Level 2+:
   - `1Password`, `Keychain Access`
   - Banking apps: any app with bundle ID containing `bank`, `chase`, `wellsfargo`, etc.
   - Private messaging: `Messages`, `Signal`, `WhatsApp`, `Telegram`
   - System apps: `Keychain Access`, `Security Agent`

3. **App allowlist mode** — Alternatively, only snapshot explicitly approved apps:
   - Terminal, iTerm2, Xcode, VS Code, Cursor
   - Slack, Linear, Notion (work tools)
   - Browsers with work domains only (filter by tab URL domain)

4. **Screenshot scrubbing** — Before transmitting screenshots, blur any `AXSecureTextField` bounds detected in the current AX tree.

5. **Window title scrubbing** — Strip file paths from window titles when filenames may be sensitive (e.g., `document.pdf` → `[document]`).

---

## Suggested cua Commands for a Remote Agent

```bash
# Level 0 — always safe
ssh james-laptop cua status
ssh james-laptop cua list

# Level 1 — app events only (query recent events, no streaming)
ssh james-laptop cua events recent --filter "app.launched,app.quit,screen.lock"

# Level 2 — structure only (labels and roles, no values)
ssh james-laptop cua snapshot Xcode --format compact
ssh james-laptop cua snapshot Terminal --format compact

# Full status check before deciding what to do
ssh james-laptop cua daemon health

# Check what's frontmost before snapshotting
STATUS=$(ssh james-laptop cua status --format json)
FRONTMOST=$(echo "$STATUS" | jq -r '.frontmost_app')
if [[ "$FRONTMOST" == "Xcode" ]]; then
  ssh james-laptop cua snapshot Xcode --format compact
fi
```

---

## Security Hardening Checklist

- [ ] Use Tailscale (private WireGuard mesh, no open ports on public internet)
- [ ] SSH key with `command=` restriction — agent can only run `cua`, nothing else
- [ ] Separate SSH key per agent — revoke one without affecting others
- [ ] Set `--format compact` on all remote snapshot calls (compact output is smaller and omits raw values)
- [ ] Review and maintain your app blocklist regularly
- [ ] Log all remote `cua` calls with timestamps (the SSH `command=` wrapper can do this)
- [ ] Never pass `--format json --pretty` over SSH — compact output reduces accidental data leakage
- [ ] Rotate agent SSH keys periodically (every 90 days or on personnel changes)

---

## Example: Hedwig Agent Configuration

Hedwig (Mac Mini) watching James's laptop (james-laptop on Tailscale):

```yaml
# hedwig skill: cua-remote
name: cua-remote
description: Observe James's laptop via cua over Tailscale SSH

commands:
  status:    ssh -i ~/.ssh/hedwig_agent_key james-laptop cua status
  list:      ssh -i ~/.ssh/hedwig_agent_key james-laptop cua list
  snapshot:  ssh -i ~/.ssh/hedwig_agent_key james-laptop cua snapshot "$APP" --format compact
  events:    ssh -i ~/.ssh/hedwig_agent_key james-laptop cua events recent
  health:    ssh -i ~/.ssh/hedwig_agent_key james-laptop cua daemon health

# Default: Level 0-1 only
# Allowed for Level 2: Xcode, Terminal, Cursor, Slack
allowed_level2_apps:
  - Xcode
  - Terminal
  - Cursor
  - Slack
```

The `command=` restriction in `authorized_keys` on James's laptop ensures that even if Hedwig's key is compromised, the attacker can only run `cua` commands — not arbitrary shell access.
