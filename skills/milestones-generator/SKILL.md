# Milestones Generator

Generate milestone YAML files for any application so `cua process watch` can emit structured progress events.

## When to Use

Use this skill when a user wants to:
- Create milestone tracking for a build pipeline, deploy script, or long-running process
- Generate a milestone YAML file from sample log output
- Customize milestone patterns for their specific toolchain

## Milestone YAML Schema

```yaml
name: <preset-name>           # Required. Short identifier (e.g., "next-build")
description: <human-readable>  # Required. What this preset tracks
format: plaintext | ndjson     # Required. Log format (plaintext for most, ndjson for Claude Code)

patterns:
  - type: <milestone-id>       # Required. Unique identifier (e.g., "building", "testing")
    match:                      # Required. At least one match criterion
      regex: <pattern>          # Regex match on raw line (or json_path values)
      any_text: <substring>     # Simple substring match on raw line
      json_path: <path>         # JSON path for ndjson format (e.g., "$.message.content[*].name")
      value: <exact>            # Exact value match (used with json_path)
      exit_code: <int>          # Match process exit code
    emoji: <single-emoji>       # Visual indicator for this milestone
    message: <static-text>      # Static message (use this OR message_template)
    message_template: <text>    # Template with {match} placeholder for matched text
    dedupe: first | transition | latest | every  # Required. Deduplication mode
```

## Match Types

### `regex`
Regular expression match. When used alone, matches against the raw log line. When used with `json_path`, matches against values at that path.

```yaml
match:
  regex: "cargo build|npm run build|go build"
```

### `any_text`
Simple substring match on the raw line. Faster than regex, good for exact markers.

```yaml
match:
  any_text: "SWARM_DONE"
```

### `json_path` + `value`
For NDJSON logs. Resolves a JSON path and checks for an exact value match. Supports `[*]` for array wildcards.

```yaml
match:
  json_path: "$.message.content[*].name"
  value: "Read"
```

### `json_path` + `regex`
For NDJSON logs. Resolves a JSON path and applies regex to the values found.

```yaml
match:
  json_path: "$.message.content[*].input.command"
  regex: "cargo test|npm test"
```

### `exit_code`
Match a specific process exit code.

```yaml
match:
  exit_code: 0
```

## Deduplication Modes

| Mode | Behavior | Use When |
|------|----------|----------|
| `first` | Emit only the first match, suppress all subsequent | One-time events: "PR created", "Done" |
| `transition` | Emit when entering this state from a different state | Phase changes: build -> test -> build emits 3 times |
| `latest` | Emit every match, updating the message | Progressive status: "5 passed" -> "10 passed" -> "15 passed" |
| `every` | Emit every match unconditionally | Docker build steps, individual test results |

## How to Generate a Milestone File

### Step 1: Identify the Application and Log Format

Ask the user:
- What application/process are they monitoring?
- Is the output plain text or NDJSON?
- Can they provide sample log output?

### Step 2: Analyze Sample Logs

Look for patterns that indicate:
1. **Phase transitions** (compilation, testing, deployment) -> use `transition` dedupe
2. **One-time markers** (PR creation, completion signal) -> use `first` dedupe
3. **Progressive counters** (test counts, coverage) -> use `latest` dedupe
4. **Repeated steps** (Docker build stages) -> use `every` dedupe

### Step 3: Write the YAML File

Create patterns for each identifiable milestone. Follow these rules:
- Each `type` must be unique within the file
- Provide either `message` (static) or `message_template` (dynamic with `{match}`)
- Use `transition` as the default dedupe mode for phase changes
- Use descriptive emoji that maps to the activity
- Test regex patterns against actual log samples
- Order patterns from earliest to latest in typical execution

### Step 4: Validate

```bash
cua milestones validate ./my-milestones.yaml
```

This checks:
- All required fields are present
- Regex patterns compile
- No duplicate type IDs
- At least one match criterion per pattern

### Step 5: Install

Copy to the milestones directory:
```bash
mkdir -p ~/.agentview/milestones
cp ./my-milestones.yaml ~/.agentview/milestones/
```

Or use directly:
```bash
cua process watch <PID> --log /path/to/log --milestones ./my-milestones.yaml
```

### Step 6: Test Against Sample Logs

To verify milestone detection works, run the watched process with milestone tracking enabled:

```bash
# Start the process and redirect output to a log file
my-command > /tmp/my-process.log 2>&1 &
PID=$!

# Watch with milestones (stream mode to see events)
cua process watch $PID --log /tmp/my-process.log --milestones my-preset --stream
```

## Example: Generating for a Next.js Build Pipeline

Given sample log output:
```
info  - Linting and checking validity of types...
info  - Creating an optimized production build...
info  - Compiled successfully
info  - Collecting page data...
info  - Generating static pages (0/10)
info  - Generating static pages (10/10)
info  - Finalizing page optimization...
info  - Route (app)                              Size     First Load JS
```

Generate:
```yaml
name: next-build
description: Next.js build pipeline milestones
format: plaintext

patterns:
  - type: linting
    match:
      regex: "Linting and checking"
    emoji: "\U0001F9F9"
    message: "Linting & type checking..."
    dedupe: transition

  - type: compiling
    match:
      regex: "Creating an optimized production build"
    emoji: "\U0001F528"
    message: "Compiling..."
    dedupe: transition

  - type: compiled
    match:
      regex: "Compiled successfully"
    emoji: "\u2705"
    message: "Compiled successfully"
    dedupe: first

  - type: collecting
    match:
      regex: "Collecting page data"
    emoji: "\U0001F4CA"
    message: "Collecting page data..."
    dedupe: transition

  - type: generating
    match:
      regex: "Generating static pages \\(\\d+/\\d+\\)"
    emoji: "\u2699\uFE0F"
    message_template: "{match}"
    dedupe: latest

  - type: finalizing
    match:
      regex: "Finalizing page optimization"
    emoji: "\U0001F3C1"
    message: "Finalizing..."
    dedupe: first

  - type: routes
    match:
      regex: "Route \\(app\\)"
    emoji: "\U0001F4CB"
    message: "Build complete - route summary"
    dedupe: first
```

## Event Output

When a milestone matches, `cua` emits a `process.milestone` event through the event system:

```json
{
  "type": "process.milestone",
  "pid": 12345,
  "timestamp": "2026-02-20T06:45:00Z",
  "details": {
    "type": "building",
    "emoji": "\U0001F528",
    "message": "Building...",
    "line_number": 847,
    "label": "issue-155"
  }
}
```

This flows through webhooks to OpenClaw, Slack, or any subscriber.

## Shipped Presets

| Preset | Format | Description |
|--------|--------|-------------|
| `claude-code` | ndjson | Claude Code agent milestones |
| `cargo` | plaintext | Rust cargo build/test/clippy |
| `npm` | plaintext | Node.js npm/yarn/pnpm build/test |
| `pytest` | plaintext | Python pytest output |
| `docker` | plaintext | Docker build stages |

List all available: `cua milestones list`
