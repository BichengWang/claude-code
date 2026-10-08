---
description: "Show the status of the active Ralph Wiggum loop"
allowed-tools: ["Bash(test -f .claude/ralph-loop.local.md:*)", "Read(.claude/ralph-loop.local.md)"]
hide-from-slash-command-tool: "true"
---

# Ralph Status

To show the status of the Ralph loop:

1. Check if `.claude/ralph-loop.local.md` exists using Bash: `test -f .claude/ralph-loop.local.md && echo "EXISTS" || echo "NOT_FOUND"`

2. **If NOT_FOUND**: Say "No active Ralph loop found."

3. **If EXISTS**: Read `.claude/ralph-loop.local.md` and report these fields from the frontmatter:
   - `iteration:` as the current iteration
   - `max_iterations:` as the iteration limit, or "unlimited" if it is 0
   - `completion_promise:` as the completion promise, or "none" if it is null
   - `started_at:` as the start time

   Do not modify the file or continue the loop.
