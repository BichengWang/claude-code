#!/bin/bash

# Ralph Wiggum Stop Hook
# Prevents session exit when a ralph-loop is active
# Feeds Claude's output back as input to continue the loop

set -euo pipefail

# Read hook input from stdin (advanced stop hook API)
HOOK_INPUT=$(cat)

# Check if ralph-loop is active
RALPH_STATE_FILE=".claude/ralph-loop.local.md"

if [[ ! -f "$RALPH_STATE_FILE" ]]; then
  # No active loop - allow exit
  exit 0
fi

# /ralph-status is a read-only inspection command. The turn that runs it must
# not advance, terminate, or otherwise touch the loop, so leave the state file
# alone and let the session stop.
#
# Typing text that looks like the command tags is not enough: a real invocation
# is recorded in the transcript as two consecutive entries of the same prompt,
#   1. a user entry with the tags
#        <command-message>...</command-message>
#        <command-name>/ralph-status</command-name>
#      (optionally namespaced as /ralph-wiggum:ralph-status), and
#   2. a hidden (isMeta) user entry holding the expanded command body, which
#      starts with the sentinel comment from commands/ralph-status.md.
# Users cannot create hidden entries, so both must be present, with nothing
# (assistant output, tool results) in between. The turn is judged by the last
# real user prompt, ignoring tool results, hook feedback and sidechains.
#
# The transcript is written asynchronously and can lag behind the session, so a
# verdict of "pending" (tagged prompt with nothing after it yet, or the current
# prompt_id not in the transcript yet) is re-checked for up to ~2 seconds.
ralph_status_verdict() {
  local transcript_path prompt_id
  transcript_path=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // empty' 2>/dev/null) || return 1
  prompt_id=$(echo "$HOOK_INPUT" | jq -r '.prompt_id // empty' 2>/dev/null) || prompt_id=""
  [[ -n "$transcript_path" && -f "$transcript_path" ]] || { echo no; return 0; }
  jq -r -R -n --arg hook_pid "$prompt_id" '
    def text: .message.content
      | if type == "string" then .
        elif type == "array" then map(select((.type? // "") == "text") | .text) | join("\n")
        else "" end;
    reduce (inputs | fromjson? | select(type == "object")) as $e (
      {open: false, tagged: false, expanded: false, pid: null};
      if $e.isSidechain == true then .
      elif $e.type == "assistant" then .open = false
      elif $e.type == "user" then
        if $e.isMeta == true then
          if .open and .tagged
             and (.pid == null or $e.promptId == null or .pid == $e.promptId)
             and ($e | text | test("^<!-- ralph-status: read-only -->"))
          then .expanded = true | .open = false
          else .open = false end
        elif (($e.message.content | type) == "array"
              and any($e.message.content[]; (.type? // "") == "tool_result")) then .open = false
        else
          {open: true, expanded: false, pid: $e.promptId,
           tagged: ($e | text | test("^<command-message>[^<]*</command-message>\\s*<command-name>/(ralph-wiggum:)?ralph-status</command-name>"))}
        end
      else . end
    )
    | if .tagged and .expanded then "status"
      elif (.tagged and .open) or ($hook_pid != "" and .pid != null and .pid != $hook_pid) then "pending"
      else "no" end
  ' "$transcript_path" 2>/dev/null || echo no
}

is_ralph_status_turn() {
  local verdict attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    verdict=$(ralph_status_verdict)
    [[ "$verdict" == "pending" ]] || break
    sleep 0.2
  done
  [[ "$verdict" == "status" ]]
}

if is_ralph_status_turn; then
  exit 0
fi

# Parse markdown frontmatter (YAML between ---) and extract values
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$RALPH_STATE_FILE")
ITERATION=$(echo "$FRONTMATTER" | grep '^iteration:' | sed 's/iteration: *//')
MAX_ITERATIONS=$(echo "$FRONTMATTER" | grep '^max_iterations:' | sed 's/max_iterations: *//')
# Extract completion_promise and strip surrounding quotes if present
COMPLETION_PROMISE=$(echo "$FRONTMATTER" | grep '^completion_promise:' | sed 's/completion_promise: *//' | sed 's/^"\(.*\)"$/\1/')

# Validate numeric fields before arithmetic operations
if [[ ! "$ITERATION" =~ ^[0-9]+$ ]]; then
  echo "⚠️  Ralph loop: State file corrupted" >&2
  echo "   File: $RALPH_STATE_FILE" >&2
  echo "   Problem: 'iteration' field is not a valid number (got: '$ITERATION')" >&2
  echo "" >&2
  echo "   This usually means the state file was manually edited or corrupted." >&2
  echo "   Ralph loop is stopping. Run /ralph-loop again to start fresh." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  echo "⚠️  Ralph loop: State file corrupted" >&2
  echo "   File: $RALPH_STATE_FILE" >&2
  echo "   Problem: 'max_iterations' field is not a valid number (got: '$MAX_ITERATIONS')" >&2
  echo "" >&2
  echo "   This usually means the state file was manually edited or corrupted." >&2
  echo "   Ralph loop is stopping. Run /ralph-loop again to start fresh." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Check if max iterations reached
if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
  echo "🛑 Ralph loop: Max iterations ($MAX_ITERATIONS) reached."
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Get transcript path from hook input
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path')

if [[ ! -f "$TRANSCRIPT_PATH" ]]; then
  echo "⚠️  Ralph loop: Transcript file not found" >&2
  echo "   Expected: $TRANSCRIPT_PATH" >&2
  echo "   This is unusual and may indicate a Claude Code internal issue." >&2
  echo "   Ralph loop is stopping." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Read last assistant message from transcript (JSONL format - one JSON per line)
# First check if there are any assistant messages
if ! grep -q '"role":"assistant"' "$TRANSCRIPT_PATH"; then
  echo "⚠️  Ralph loop: No assistant messages found in transcript" >&2
  echo "   Transcript: $TRANSCRIPT_PATH" >&2
  echo "   This is unusual and may indicate a transcript format issue" >&2
  echo "   Ralph loop is stopping." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Extract last assistant message with explicit error handling
LAST_LINE=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" | tail -1)
if [[ -z "$LAST_LINE" ]]; then
  echo "⚠️  Ralph loop: Failed to extract last assistant message" >&2
  echo "   Ralph loop is stopping." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Parse JSON with error handling
LAST_OUTPUT=$(echo "$LAST_LINE" | jq -r '
  .message.content |
  map(select(.type == "text")) |
  map(.text) |
  join("\n")
' 2>&1)

# Check if jq succeeded
if [[ $? -ne 0 ]]; then
  echo "⚠️  Ralph loop: Failed to parse assistant message JSON" >&2
  echo "   Error: $LAST_OUTPUT" >&2
  echo "   This may indicate a transcript format issue" >&2
  echo "   Ralph loop is stopping." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

if [[ -z "$LAST_OUTPUT" ]]; then
  echo "⚠️  Ralph loop: Assistant message contained no text content" >&2
  echo "   Ralph loop is stopping." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Check for completion promise (only if set)
if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  # Extract text from <promise> tags using Perl for multiline support
  # -0777 slurps entire input, s flag makes . match newlines
  # .*? is non-greedy (takes FIRST tag), whitespace normalized
  PROMISE_TEXT=$(echo "$LAST_OUTPUT" | perl -0777 -pe 's/.*?<promise>(.*?)<\/promise>.*/$1/s; s/^\s+|\s+$//g; s/\s+/ /g' 2>/dev/null || echo "")

  # Use = for literal string comparison (not pattern matching)
  # == in [[ ]] does glob pattern matching which breaks with *, ?, [ characters
  if [[ -n "$PROMISE_TEXT" ]] && [[ "$PROMISE_TEXT" = "$COMPLETION_PROMISE" ]]; then
    echo "✅ Ralph loop: Detected <promise>$COMPLETION_PROMISE</promise>"
    rm "$RALPH_STATE_FILE"
    exit 0
  fi
fi

# Not complete - continue loop with SAME PROMPT
NEXT_ITERATION=$((ITERATION + 1))

# Extract prompt (everything after the closing ---)
# Skip first --- line, skip until second --- line, then print everything after
# Use i>=2 instead of i==2 to handle --- in prompt content
PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$RALPH_STATE_FILE")

if [[ -z "$PROMPT_TEXT" ]]; then
  echo "⚠️  Ralph loop: State file corrupted or incomplete" >&2
  echo "   File: $RALPH_STATE_FILE" >&2
  echo "   Problem: No prompt text found" >&2
  echo "" >&2
  echo "   This usually means:" >&2
  echo "     • State file was manually edited" >&2
  echo "     • File was corrupted during writing" >&2
  echo "" >&2
  echo "   Ralph loop is stopping. Run /ralph-loop again to start fresh." >&2
  rm "$RALPH_STATE_FILE"
  exit 0
fi

# Update iteration in frontmatter (portable across macOS and Linux)
# Create temp file, then atomically replace
TEMP_FILE="${RALPH_STATE_FILE}.tmp.$$"
sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$RALPH_STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$RALPH_STATE_FILE"

# Build system message with iteration count and completion promise info
if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  SYSTEM_MSG="🔄 Ralph iteration $NEXT_ITERATION | To stop: output <promise>$COMPLETION_PROMISE</promise> (ONLY when statement is TRUE - do not lie to exit!)"
else
  SYSTEM_MSG="🔄 Ralph iteration $NEXT_ITERATION | No completion promise set - loop runs infinitely"
fi

# Output JSON to block the stop and feed prompt back
# The "reason" field contains the prompt that will be sent back to Claude
jq -n \
  --arg prompt "$PROMPT_TEXT" \
  --arg msg "$SYSTEM_MSG" \
  '{
    "decision": "block",
    "reason": $prompt,
    "systemMessage": $msg
  }'

# Exit 0 for successful hook execution
exit 0
