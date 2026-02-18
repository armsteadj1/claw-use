# Create Pull Request

After completing your work, create a pull request using the GitHub CLI.

## Steps

1. Make sure all changes are committed and pushed to the branch
2. Create the PR with:

```bash
gh pr create \
  --title "<concise title describing what was built>" \
  --body "<PR body following the template below>" \
  --base main
```

## PR Body Template

Use this structure for the PR body:

```markdown
## Summary
<1-2 sentences describing what this PR does and why>

## Changes
- <bullet list of key changes, grouped by file/area>

## Testing
- <how it was tested>
- <test results: X tests passing>

## Review Notes
<anything reviewers should pay attention to — security changes, breaking changes, trade-offs made>
```

## Rules
- Title should be imperative mood ("Add feature X" not "Added feature X")
- Keep the summary brief — details go in Changes
- Always include test results
- If this closes an issue, add "Closes #N" to the summary
- Don't create draft PRs unless explicitly asked
