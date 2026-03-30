# Remote Use

cua needs direct access to macOS Accessibility APIs and local Unix domain sockets — so it runs on the Mac being observed. But your agent can live anywhere. This guide shows how to connect the two securely.

---

## How It Works

**Two machines, one secure channel:**

- **Observed Mac** — runs `cuad`. Listens on an HTTP port, locked to your Tailscale network.
- **Agent machine** — knows a shared secret. Does a quick HMAC handshake, then talks to `cuad` directly over HTTP.

No SSH daemon. No port forwarding. No key management. Just Tailscale (for the encrypted private network) and a shared secret (for application-level auth).

```
Agent Machine (Mac Mini)             Observed Mac (Laptop)
┌──────────────────────┐             ┌──────────────────────┐
│  agent / cua client  │──Tailscale──│  cuad (HTTP :4567)   │
│                      │   WireGuard │  HMAC auth           │
│  HMAC-signed request │────────────▶│  runs cua commands   │
└──────────────────────┘             └──────────────────────┘
```

**What each layer does:**

| Layer | What it provides |
|-------|-----------------|
| Tailscale | Wire encryption (WireGuard), network-level access control — only YOUR devices can reach the port |
| HMAC handshake | Application-level auth — only the agent with the shared secret can talk to cuad |
| cuad HTTP API | Command restriction — the agent can only do what cuad exposes. No shell, no filesystem, nothing else. |

---

## Setup (5 minutes)

### 1. Install Tailscale on both machines

```bash
brew install tailscale
tailscale up
```

Both machines appear in your Tailscale console with stable hostnames (e.g., `james-laptop`, `hedwig-mini`).

### 2. Generate a shared secret

Run this on either machine — just needs to be the same on both:

```bash
openssl rand -hex 32
# → a3f8c2d1e4b5... (save this)
```

### 3. Configure the observed Mac

Edit `~/.cua/config.json` on the Mac being observed:

```json
{
  "remote": {
    "enabled": true,
    "port": 4567,
    "bind": "tailscale",
    "secret": "your-shared-secret-here"
  }
}
```

- `"bind": "tailscale"` — cuad only listens on the Tailscale interface. Not reachable from the public internet or your local LAN.
- `"bind": "localhost"` — local only (for testing)
- `"bind": "0.0.0.0"` — all interfaces (not recommended; rely on Tailscale ACLs if you do this)

Restart the daemon:

```bash
cua daemon restart
```

### 4. Configure the agent machine

Edit `~/.cua/config.json` on the agent machine:

```json
{
  "remote_targets": {
    "james-laptop": {
      "url": "http://james-laptop:4567",
      "secret": "your-shared-secret-here"
    }
  }
}
```

### 5. Test it

```bash
# From the agent machine
cua --remote james-laptop status
# → {"daemon":"running","screen":"unlocked","frontmost":"Safari"}

cua --remote james-laptop list
cua --remote james-laptop snapshot Safari --format compact
```

---

## The Handshake

Every session opens with a challenge-response exchange:

```
Agent → cuad:  GET /handshake
               ← {challenge: "abc123", expires_in: 30}

Agent → cuad:  POST /auth
               {sig: HMAC-SHA256(secret, challenge + timestamp)}
               ← {token: "sess_...", ttl: 3600}

Agent → cuad:  POST /rpc  (all subsequent calls)
               Authorization: Bearer sess_...
               {method: "snapshot", params: {app: "Safari"}}
```

The challenge expires in 30 seconds. The session token lives for 1 hour (configurable). A compromised session token can only speak the cuad RPC protocol — there's no shell, no file access, nothing to escalate to.

---

## For the Agent

Use the `--remote` flag on any cua command:

```bash
cua --remote james-laptop status
cua --remote james-laptop list
cua --remote james-laptop snapshot Safari --format compact
cua --remote james-laptop act Safari click --ref e4
cua --remote james-laptop screenshot Xcode
```

Or set it as an environment variable for a session:

```bash
export CUA_REMOTE=james-laptop
cua status
cua snapshot Safari
```

**OpenClaw skill config:**

```yaml
name: cua-remote
description: See and interact with James's laptop via cua remote
commands:
  status:    cua --remote james-laptop status
  list:      cua --remote james-laptop list
  snapshot:  cua --remote james-laptop snapshot "$APP" --format compact
  act:       cua --remote james-laptop act "$APP" "$ACTION" --ref "$REF"
```

Always use `--format compact` for remote snapshots — it's 5× smaller than the default.

---

## What the Agent Can See

Access is tiered by privacy level. Configure per-app in `~/.cua/config.json`.

| Level | Name | What's Visible |
|-------|------|----------------|
| 0 | Status | App names, screen lock state, frontmost app |
| 1 | Events | App launches/quits, focus changes, screen unlock |
| 2 | Structure | UI labels, roles, window titles — NOT field values |
| 3 | Full | Everything: field values, page content, screenshots |

**Recommended defaults:**

- Level 0–1 for ambient awareness
- Level 2 only for approved work apps (Terminal, Xcode, VS Code, Slack)
- Level 3 requires explicit per-app consent

---

## Security Notes

- **Tailscale does the heavy lifting.** WireGuard encryption + your Tailscale ACLs mean the port is invisible to anyone not on your network. The HMAC layer is defense-in-depth.
- **No shell access.** A compromised session token can only speak the cuad RPC protocol. There's nothing to escalate to.
- **One secret per observer.** Generate a different secret for each Mac being observed. Rotating one doesn't affect others.
- **Session tokens expire.** Default 1 hour. Configure shorter in `remote.token_ttl` if needed.
- **Blocklist sensitive apps.** Configure apps that should never be snapshotted remotely (1Password, banking apps, Messages) in `remote.blocked_apps`.

```json
{
  "remote": {
    "enabled": true,
    "port": 4567,
    "bind": "tailscale",
    "secret": "your-secret",
    "token_ttl": 3600,
    "blocked_apps": ["1Password", "Keychain Access", "Messages", "Signal"]
  }
}
```
