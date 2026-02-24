# Remote Use

cua needs direct access to macOS Accessibility APIs and local Unix domain sockets — so it runs on the Mac being observed. But your agent can live anywhere. This guide shows how to connect the two securely.

---

## The Setup (5 minutes)

**What you need:** cua installed on the Mac to observe, Tailscale on both machines.

### 1. Install Tailscale on both machines

```bash
brew install tailscale
tailscale up
```

Both machines should appear in your Tailscale admin console. They'll get stable hostnames (e.g., `james-laptop`, `hedwig-mini`) you can use in SSH commands.

### 2. Create a dedicated SSH key for the agent

Run this on the agent machine:

```bash
ssh-keygen -t ed25519 -C "hedwig-agent" -f ~/.ssh/hedwig_agent_key
```

Use a separate key per agent — this lets you revoke access for one agent without touching others.

### 3. Add the key to the laptop with a `command=` restriction

On the Mac being observed, open `~/.ssh/authorized_keys` and add:

```
command="/usr/local/bin/cua $SSH_ORIGINAL_COMMAND",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAA... hedwig-agent
```

Replace `AAAA...` with the contents of `~/.ssh/hedwig_agent_key.pub`.

The `command=` prefix means a compromised key can only run `cua` — not arbitrary shell commands, no port forwarding, nothing else.

### 4. Test the connection

From the agent machine:

```bash
ssh -i ~/.ssh/hedwig_agent_key james-laptop status
# → {"daemon":"running","screen":"unlocked","frontmost":"Safari"}
```

That's it. The agent now has eyes and hands on the laptop.

---

## For the Agent

The agent uses SSH to prefix every cua command. Here's a skill config:

```yaml
# skill: cua-remote
# Hedwig (Mac Mini) watching James's laptop via Tailscale SSH
commands:
  status:   ssh -i ~/.ssh/hedwig_agent_key james-laptop cua status
  list:     ssh -i ~/.ssh/hedwig_agent_key james-laptop cua list
  snapshot: ssh -i ~/.ssh/hedwig_agent_key james-laptop cua snapshot "$APP" --format compact
  act:      ssh -i ~/.ssh/hedwig_agent_key james-laptop cua act "$APP" "$ACTION" --ref "$REF"
```

Example agent commands:

```bash
ssh -i ~/.ssh/hedwig_agent_key james-laptop cua status
ssh -i ~/.ssh/hedwig_agent_key james-laptop cua list
ssh -i ~/.ssh/hedwig_agent_key james-laptop cua snapshot Safari --format compact
ssh -i ~/.ssh/hedwig_agent_key james-laptop cua act Safari click --ref e4
```

Always use `--format compact` for remote snapshots — it's 5x smaller than the default and cuts SSH round-trip costs significantly.

---

## What the Agent Can See

Access is tiered by privacy level. Configure per-app in cua settings.

| Level | Name | What's Visible |
|-------|------|----------------|
| 0 | Status | App names, screen lock state, frontmost app |
| 1 | Events | App launches/quits, focus changes, screen unlock |
| 2 | Structure | UI labels, roles, window titles, button names — but NOT field values |
| 3 | Full | Everything: field values, page content, screenshots |

**Recommended defaults:**

- Level 0–1 for general awareness
- Level 2 only for approved work apps (Terminal, Xcode, VS Code, Slack)
- Level 3 requires explicit per-app consent from the user

The agent can always see which apps are running (Level 0). Reading what's in those apps requires higher levels.

---

## Sensitive Data

Some apps should never be exposed, regardless of level.

**Never expose:**
- Password fields — `AXSecureTextField` values are always redacted, even at Level 3
- 1Password, Keychain Access
- Banking apps (Chase, Fidelity, etc.)
- Messages, Signal, WhatsApp, Telegram

**Implementation pattern:** maintain an app blocklist (never visible) and an app allowlist (explicitly approved). Default everything else to Level 0.

```
# blocklist — always denied
1Password
Keychain Access
Messages
Signal

# allowlist — approved for Level 2
Terminal
Xcode
Visual Studio Code
Slack
```

If an agent tries to snapshot a blocklisted app, cua returns an error: `access denied: app is on blocklist`.

---

## Security Checklist

- **Tailscale** — no open ports on the public internet; NAT traversal handled automatically
- **SSH `command=` restriction** — compromised key can only run `cua`, not arbitrary shell
- **Separate key per agent** — revoke one agent's access without affecting others
- **`--format compact`** on all remote snapshot calls — smaller output, faster round-trips
- **App blocklist** — sensitive apps explicitly denied
- **Log all remote `cua` calls** with timestamps for auditability
- **Review Tailscale ACLs** — restrict which machines can reach the laptop if needed
