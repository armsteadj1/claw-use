# Install Guide

All install methods, update instructions, and permissions setup.

---

## Requirements

- macOS 15.0 or later
- Accessibility permission (System Settings → Privacy & Security → Accessibility)
- For Safari web commands: Safari → Develop → Allow JavaScript from Apple Events

---

## Install Methods

### Homebrew (recommended)

```bash
brew install armsteadj1/tap/cua
```

To check what's installed:

```bash
cua --version
```

---

### Shell Script

Downloads the latest pre-built universal binary directly from GitHub Releases.

```bash
curl -fsSL https://raw.githubusercontent.com/armsteadj1/claw-use/main/install.sh | sh
```

Installs `cua` and `cuad` to `/usr/local/bin` (or `~/.local/bin` if `/usr/local/bin` isn't writable).

To preview what will be installed without installing:

```bash
curl -fsSL https://raw.githubusercontent.com/armsteadj1/claw-use/main/install.sh | sh -s -- --version
```

---

### Build from Source

Requires Swift 5.9+ (comes with Xcode or Swift toolchain).

```bash
git clone https://github.com/armsteadj1/claw-use.git
cd claw-use
swift build -c release
cp .build/release/cua .build/release/cuad ~/.local/bin/
```

---

### Manual Binary Download

1. Go to [github.com/armsteadj1/claw-use/releases/latest](https://github.com/armsteadj1/claw-use/releases/latest)
2. Download `cua-macos-universal.tar.gz`
3. Extract: `tar xzf cua-macos-universal.tar.gz`
4. Move to your PATH: `mv cua cuad /usr/local/bin/`
5. Make executable: `chmod +x /usr/local/bin/cua /usr/local/bin/cuad`

---

## Permissions Setup

### Accessibility (required for native apps)

1. Open **System Settings → Privacy & Security → Accessibility**
2. Click the **+** button
3. Add your terminal app (Terminal, iTerm2, Warp, etc.) **or** add `cua` directly
4. Toggle the switch to **On**

Without this, snapshots of native apps return empty or partial results.

### Safari JavaScript Execution (required for web commands)

1. Open **Safari**
2. Go to **Develop → Allow JavaScript from Apple Events**

If you don't see the Develop menu:
1. Safari → **Settings** → **Advanced**
2. Check **Show Develop menu in menu bar**

---

## PATH Setup

The shell script installer will tell you if your install directory isn't in PATH. Here's how to add it:

### bash

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### zsh

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### fish

```fish
fish_add_path ~/.local/bin
```

---

## Post-Install: Start the Daemon

```bash
cua daemon start
# → {"status":"started","pid":12345}
```

Verify it's running:

```bash
cua status
# → daemon: running | screen: unlocked | CDP: 0 connections
```

To stop the daemon:

```bash
cua daemon stop
```

---

## Update

### Using `cua update`

```bash
cua update
```

This checks the latest GitHub release, compares with your installed version, and installs if there's a newer version.

```
Checking for updates...
New version available: v0.4.0 (you have v0.3.0)
Downloading v0.4.0...
Installed cua and cuad to /usr/local/bin
Updated to v0.4.0.
Restart cuad to run the new daemon: cua daemon stop && cua daemon start
```

After updating, restart the daemon:

```bash
cua daemon stop && cua daemon start
```

### Via Homebrew

```bash
brew upgrade armsteadj1/tap/cua
cua daemon stop && cua daemon start
```

### Via Shell Script (re-run)

```bash
curl -fsSL https://raw.githubusercontent.com/armsteadj1/claw-use/main/install.sh | sh
cua daemon stop && cua daemon start
```

---

## Check Your Version

```bash
cua --version
# → cua 0.3.0
```

cua also notifies you when a newer version is available — you'll see a notice on your next command:

```
⚡ cua v0.4.0 available (you have v0.3.0). Run `cua update` to upgrade.
```

---

## Uninstall

```bash
# Stop the daemon
cua daemon stop

# Remove binaries
rm /usr/local/bin/cua /usr/local/bin/cuad
# or: rm ~/.local/bin/cua ~/.local/bin/cuad

# Remove cua data directory (optional)
rm -rf ~/.cua
```

To uninstall Homebrew tap:

```bash
brew uninstall armsteadj1/tap/cua
```

---

## Remote Setup (Agent on One Machine, Mac on Another)

See [REMOTE.md](REMOTE.md) for the full guide.

Quick version:
1. Install cua on the Mac you want to observe
2. Install Tailscale on both machines
3. Create an SSH key for the agent with `command=` restriction
4. Agent runs: `ssh your-mac cua snapshot Safari`
