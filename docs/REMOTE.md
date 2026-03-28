# cua Remote Access

Remote access lets an agent on one Mac observe and control a human's Mac over Tailscale using a simple pairing ceremony.

---

## Pairing Flow

### Step 1 — Agent runs `cua remote accept`

On the agent machine (e.g. Mac Mini):

```bash
cua remote accept
```

Output:
```
🔗 Ready to pair. Send this to your human:

   cua remote pair 100.80.200.51:4567 a3f1-9c2b

Waiting... (Ctrl+C to cancel)
```

### Step 2 — Agent sends the command to the human

The agent sends the command via Slack, chat, or any channel:

> Hey — run this on your laptop so I can see your screen:
>
> `cua remote pair 100.80.200.51:4567 a3f1-9c2b`

### Step 3 — Human runs `cua remote pair` on their laptop

```bash
cua remote pair 100.80.200.51:4567 a3f1-9c2b
```

Output:
```
✅ Paired with hedwig-mini. Your agent can now see your screen.
Run 'cua daemon restart' to apply the new config.
```

### Step 4 — Agent sees it complete

`cua remote accept` exits:
```
✅ Paired with james-laptop (100.64.x.x).
   Try: cua --remote james-laptop status
```

Both machines' configs are written automatically. No JSON copy-paste.

---

## After Pairing

The agent can now use any `cua` command with `--remote <name>`:

```bash
cua --remote james-laptop status
cua --remote james-laptop list
cua --remote james-laptop snapshot Safari
cua --remote james-laptop screenshot Safari
cua --remote james-laptop pipe Safari click --match "Sign In"
```

---

## How It Works

| Machine | Role | What happens during pairing |
|---------|------|----------------------------|
| Agent (Mac Mini) | Runs `cua remote accept` | Binds to Tailscale IP, generates short code, waits for POST /pair |
| Human (laptop) | Runs `cua remote pair` | Sends code to accept server, receives shared HMAC secret |

After pairing:
- Human's `~/.cua/config.json` gets a `remote` block with the shared secret — `cuad` exposes an HMAC-authenticated HTTP proxy
- Agent's `~/.cua/config.json` gets a `remote_targets` entry pointing to the human's machine

The human's `cuad` must be restarted to pick up the new config (`cua daemon restart`).

---

## Security

- **Tailscale provides network-layer encryption** — the HTTP traffic goes over Tailscale's WireGuard tunnel
- **HMAC-SHA256 authentication** — every API call requires a valid session token obtained via challenge-response
- **Pairing code is single-use, expires in 5 minutes** — replays and brute-force are prevented
- **IP filtering** — the remote server only accepts connections from the Tailscale CGNAT range (100.64.0.0/10) by default
- **App blocklist** — sensitive apps (1Password, Keychain Access, Messages, Signal) are blocked from remote access by default

---

## Options

### `cua remote accept`

```
OPTIONS:
  --bind <bind>   Bind address: tailscale (default), localhost, 0.0.0.0
  --port <port>   Port to listen on (default: 4567)
  --name <name>   Name for this machine (default: hostname)
```

### `cua remote pair <host> <code>`

```
ARGUMENTS:
  <host>   Host (IP or hostname, optionally with :port) from cua remote accept
  <code>   Pairing code from cua remote accept
```

---

## Troubleshooting

**"no Tailscale IP found"** — Install Tailscale and connect to your network. The `--bind 0.0.0.0` flag will accept connections from any interface.

**"pairing failed"** — Check that `cua remote accept` is still running on the agent machine and the pairing code hasn't expired (5-minute window).

**Agent can't connect after pairing** — The human must restart `cuad`:
```bash
cua daemon restart
```
