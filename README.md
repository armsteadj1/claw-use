# AgentView

> Make any macOS app agent-legible without screenshots.

A Swift CLI that reads macOS Accessibility APIs and exposes structured, actionable UI state to AI agents. Like Playwright, but for **every** macOS app.

**Before AgentView:** Agent takes screenshot → sends to vision model → "I see a search box at roughly these coordinates" → clicks → takes another screenshot → repeat. Slow, expensive, brittle.

**After AgentView:** Agent calls `agentview snapshot Chrome` → gets structured JSON with all content, fields, and actions → fills fields by reference → done in one round trip. Fast, cheap, reliable.

## Quick Start

```bash
# Build
swift build

# List running apps
agentview list

# Snapshot an app
agentview snapshot "Google Chrome"

# Take an action
agentview act "Google Chrome" click --ref e4
```

## Requirements

- macOS 13+ (Ventura)
- Accessibility permission (System Settings → Privacy & Security → Accessibility)
- Swift 5.9+

## Architecture

```
AI Agent (OpenClaw, Claude, any LLM)
    ↓  JSON over CLI / UDS socket
AgentView
    ├── AX Bridge (reads macOS Accessibility API)
    ├── Enrichment Engine (prunes, groups, assigns refs)
    └── App Enhancers (app-specific intelligence)
    ↓
macOS Accessibility API
    ↓
Any Running App (Chrome, Slack, Terminal, VS Code, etc.)
```

See [docs/semuid-poc.md](docs/semuid-poc.md) for the full design doc.

## License

MIT
