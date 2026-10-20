#!/bin/bash

# Tests for hooks/stop-hook.sh using synthetic hook input and transcript fixtures.
# Usage: tests/test-stop-hook.sh   (requires bash, jq, perl, shasum or sha256sum)

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hooks/stop-hook.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

check() {
  local name="$1" cond="$2"
  if eval "$cond"; then
    PASS=$((PASS + 1))
    echo "ok   - $name"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - $name   [$cond]"
  fi
}

# --- fixture builders --------------------------------------------------------

# user_prompt CONTENT: a real user prompt entry
user_prompt() { jq -nc --arg c "$1" '{type:"user",message:{role:"user",content:$c}}'; }
# meta_user CONTENT: a hidden (isMeta) user entry, e.g. expanded command body or hook feedback
meta_user() { jq -nc --arg c "$1" '{type:"user",isMeta:true,message:{role:"user",content:[{type:"text",text:$c}]}}'; }
# tool_result: user entry carrying a tool result
tool_result() { jq -nc '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"t1",content:"EXISTS"}]}}'; }
# assistant_tool_use / assistant_text
assistant_tool_use() { jq -nc '{type:"assistant",message:{role:"assistant",content:[{type:"tool_use",id:"t1",name:"Bash",input:{command:"true"}}]}}'; }
assistant_text() { jq -nc --arg t "$1" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}'; }

status_command() {
  printf '<command-message>%s</command-message>\n<command-name>%s</command-name>' "$1" "$2"
}

# status_transcript NAME-AS-TYPED: a complete /ralph-status turn
status_transcript() {
  local msg="${1#/}"
  {
    user_prompt "$(status_command "$msg" "$1")"
    meta_user "# Ralph Status ... Do not modify the file or continue the loop."
    assistant_tool_use
    tool_result
    assistant_tool_use
    tool_result
    assistant_text "The Ralph loop is active. Current iteration: 2"
  }
}

# --- harness -----------------------------------------------------------------

# new_case: fresh project dir with an active loop state file; sets PROJ
new_case() {
  PROJ=$(mktemp -d "$WORK/proj.XXXXXX")
  mkdir -p "$PROJ/.claude"
  write_state "${1:-2}" "${2:-10}" '"DONE"'
}

write_state() {
  cat > "$PROJ/.claude/ralph-loop.local.md" <<EOF
---
active: true
iteration: $1
max_iterations: $2
completion_promise: $3
started_at: "2026-10-19T00:00:00Z"
---

Build a thing
with a second line in the prompt
EOF
}

# run_hook TRANSCRIPT_FILE: runs the hook in $PROJ; sets OUT, ERR, RC
run_hook() {
  local input
  input=$(jq -nc --arg p "$1" '{session_id:"s1",transcript_path:$p,cwd:"/x",hook_event_name:"Stop",stop_hook_active:false,last_assistant_message:"x"}')
  OUT=$(cd "$PROJ" && echo "$input" | bash "$HOOK" 2>"$WORK/err")
  RC=$?
  ERR=$(cat "$WORK/err")
}

STATE() { echo "$PROJ/.claude/ralph-loop.local.md"; }
iteration() { grep '^iteration:' "$(STATE)" | sed 's/iteration: *//'; }
no_stray_files() { [[ $(ls -A "$PROJ/.claude" | wc -l) -eq 1 ]]; }

# --- cases -------------------------------------------------------------------

echo "# status turns leave the loop untouched"

for typed in /ralph-wiggum:ralph-status /ralph-status; do
  new_case 2 10
  status_transcript "$typed" > "$WORK/t.jsonl"
  before=$(sha "$(STATE)")
  run_hook "$WORK/t.jsonl"
  check "[$typed] exits 0" "[[ $RC -eq 0 ]]"
  check "[$typed] emits no block decision" "[[ -z \"\$OUT\" ]]"
  check "[$typed] state file byte-identical" "[[ \$(sha \"\$(STATE)\") == $before ]]"
  check "[$typed] iteration unchanged" "[[ \$(iteration) == 2 ]]"
  check "[$typed] no stray temp files" "no_stray_files"
done

new_case 2 10
{
  user_prompt "$(status_command ralph-wiggum:ralph-status /ralph-wiggum:ralph-status)
<command-args></command-args>"
  meta_user "# Ralph Status"
  assistant_text "The Ralph loop is active."
} > "$WORK/t.jsonl"
before=$(sha "$(STATE)")
run_hook "$WORK/t.jsonl"
check "[status with command-args tag] bypassed" "[[ \$(sha \"\$(STATE)\") == $before && -z \"\$OUT\" && $RC -eq 0 ]]"

# Status on a loop at its limit must not delete the file either
new_case 10 10
status_transcript /ralph-wiggum:ralph-status > "$WORK/t.jsonl"
before=$(sha "$(STATE)")
run_hook "$WORK/t.jsonl"
check "[status at max_iterations] state file kept, byte-identical" "[[ -f \"\$(STATE)\" && \$(sha \"\$(STATE)\") == $before && $RC -eq 0 ]]"

# Status turn whose final assistant message has no text (the reviewer's repro)
new_case 2 10
{
  user_prompt "$(status_command ralph-wiggum:ralph-status /ralph-wiggum:ralph-status)"
  meta_user "# Ralph Status"
  assistant_tool_use
  tool_result
  assistant_tool_use
} > "$WORK/t.jsonl"
before=$(sha "$(STATE)")
run_hook "$WORK/t.jsonl"
check "[status, last assistant message has no text] state file kept" "[[ -f \"\$(STATE)\" && \$(sha \"\$(STATE)\") == $before && -z \"\$OUT\" && $RC -eq 0 ]]"

# Status on a corrupted state file must not delete it
new_case 2 10
sed -i.bak 's/^iteration: .*/iteration: oops/' "$(STATE)" && rm -f "$(STATE).bak"
status_transcript /ralph-wiggum:ralph-status > "$WORK/t.jsonl"
before=$(sha "$(STATE)")
run_hook "$WORK/t.jsonl"
check "[status on corrupted state] state file kept, byte-identical" "[[ -f \"\$(STATE)\" && \$(sha \"\$(STATE)\") == $before && $RC -eq 0 ]]"

# Status with an unreadable/missing transcript is not detectable; behaviour is the old one
echo "# non-status turns keep the existing behaviour"

new_case 2 10
{
  user_prompt "Build a thing"
  assistant_text "Working on it"
} > "$WORK/t.jsonl"
cp "$(STATE)" "$WORK/orig"
run_hook "$WORK/t.jsonl"
check "[normal turn] exits 0" "[[ $RC -eq 0 ]]"
check "[normal turn] blocks" "[[ \$(echo \"\$OUT\" | jq -r .decision) == block ]]"
check "[normal turn] feeds the prompt back" "[[ \$(echo \"\$OUT\" | jq -r .reason) == \$'\nBuild a thing\nwith a second line in the prompt' ]]"
check "[normal turn] system message" "[[ \$(echo \"\$OUT\" | jq -r .systemMessage) == *'Ralph iteration 3'*'<promise>DONE</promise>'* ]]"
check "[normal turn] iteration 2 -> 3" "[[ \$(iteration) == 3 ]]"
check "[normal turn] only the iteration line changed" "[[ \$(diff <(sed 's/^iteration: .*//' \"\$(STATE)\") <(sed 's/^iteration: .*//' \"\$WORK/orig\") | wc -l) -eq 0 ]]"

# ralph-loop's own first turn
new_case 1 10
{
  user_prompt "$(status_command ralph-wiggum:ralph-loop /ralph-wiggum:ralph-loop)
<command-args>Build a thing</command-args>"
  meta_user "# Ralph Loop Command ..."
  assistant_text "Starting"
} > "$WORK/t.jsonl"
run_hook "$WORK/t.jsonl"
check "[/ralph-loop turn] blocks and increments" "[[ \$(echo \"\$OUT\" | jq -r .decision) == block && \$(iteration) == 2 ]]"

# Loop continuation turns (hook feedback is recorded as a hidden user entry)
new_case 3 10
{
  user_prompt "Build a thing"
  assistant_text "Round 1"
  meta_user "Stop hook feedback:
Build a thing"
  assistant_text "Round 2"
} > "$WORK/t.jsonl"
run_hook "$WORK/t.jsonl"
check "[loop continuation turn] blocks and increments" "[[ \$(echo \"\$OUT\" | jq -r .decision) == block && \$(iteration) == 4 ]]"

# A status turn earlier in the session must not bypass a later normal turn
new_case 2 10
{
  status_transcript /ralph-wiggum:ralph-status
  user_prompt "Carry on with the task"
  assistant_text "Continuing"
} > "$WORK/t.jsonl"
run_hook "$WORK/t.jsonl"
check "[normal turn after earlier status turn] blocks and increments" "[[ \$(echo \"\$OUT\" | jq -r .decision) == block && \$(iteration) == 3 ]]"

# A status turn after a normal turn does bypass
new_case 2 10
{
  user_prompt "Build a thing"
  assistant_text "Working on it"
  status_transcript /ralph-wiggum:ralph-status
} > "$WORK/t.jsonl"
before=$(sha "$(STATE)")
run_hook "$WORK/t.jsonl"
check "[status turn after a normal turn] bypassed" "[[ \$(sha \"\$(STATE)\") == $before && -z \"\$OUT\" && $RC -eq 0 ]]"

# Prompts that merely mention the command, or other commands, never bypass
new_case 2 10
{
  user_prompt "please explain <command-name>/ralph-wiggum:ralph-status</command-name>"
  assistant_text "Sure"
} > "$WORK/t.jsonl"
run_hook "$WORK/t.jsonl"
check "[prompt mentioning the command tag mid-text] not bypassed" "[[ \$(iteration) == 3 ]]"

new_case 2 10
{
  user_prompt "$(status_command ralph-wiggum:cancel-ralph /ralph-wiggum:cancel-ralph)"
  assistant_text "Cancelling"
} > "$WORK/t.jsonl"
run_hook "$WORK/t.jsonl"
check "[other command] not bypassed" "[[ \$(iteration) == 3 ]]"

new_case 2 10
{
  user_prompt "$(status_command other:ralph-status /other:ralph-status)"
  assistant_text "Other plugin"
} > "$WORK/t.jsonl"
run_hook "$WORK/t.jsonl"
check "[same command name from another plugin] not bypassed" "[[ \$(iteration) == 3 ]]"

echo "# termination paths are unchanged"

new_case 10 10
{ user_prompt "Build a thing"; assistant_text "Working"; } > "$WORK/t.jsonl"
run_hook "$WORK/t.jsonl"
check "[max iterations] stops, deletes state, exit 0" "[[ $RC -eq 0 && ! -e \"\$(STATE)\" && \"\$OUT\" == *'Max iterations (10) reached'* ]]"

new_case 2 10
{ user_prompt "Build a thing"; assistant_text "All done <promise>DONE</promise>"; } > "$WORK/t.jsonl"
run_hook "$WORK/t.jsonl"
check "[completion promise] stops, deletes state, exit 0" "[[ $RC -eq 0 && ! -e \"\$(STATE)\" && \"\$OUT\" == *'Detected <promise>DONE</promise>'* ]]"

new_case 2 10
{ user_prompt "Build a thing"; assistant_text "Not finished <promise>NOPE</promise>"; } > "$WORK/t.jsonl"
run_hook "$WORK/t.jsonl"
check "[wrong promise] continues" "[[ \$(iteration) == 3 && \$(echo \"\$OUT\" | jq -r .decision) == block ]]"

new_case 2 10
sed -i.bak 's/^iteration: .*/iteration: oops/' "$(STATE)" && rm -f "$(STATE).bak"
{ user_prompt "Build a thing"; assistant_text "Working"; } > "$WORK/t.jsonl"
run_hook "$WORK/t.jsonl"
check "[corrupted iteration, normal turn] deletes state, exit 0" "[[ $RC -eq 0 && ! -e \"\$(STATE)\" && \"\$ERR\" == *'State file corrupted'* ]]"

new_case 2 10
{ user_prompt "Build a thing"; assistant_tool_use; } > "$WORK/t.jsonl"
run_hook "$WORK/t.jsonl"
check "[no assistant text, normal turn] deletes state, exit 0" "[[ $RC -eq 0 && ! -e \"\$(STATE)\" && \"\$ERR\" == *'contained no text content'* ]]"

new_case 2 10
run_hook "$WORK/does-not-exist.jsonl"
check "[missing transcript] deletes state, exit 0" "[[ $RC -eq 0 && ! -e \"\$(STATE)\" && \"\$ERR\" == *'Transcript file not found'* ]]"

new_case 2 0
{ user_prompt "Build a thing"; assistant_text "Working"; } > "$WORK/t.jsonl"
run_hook "$WORK/t.jsonl"
check "[unlimited loop] continues" "[[ \$(iteration) == 3 && \$(echo \"\$OUT\" | jq -r .decision) == block ]]"

new_case 2 10
rm "$(STATE)"
status_transcript /ralph-wiggum:ralph-status > "$WORK/t.jsonl"
run_hook "$WORK/t.jsonl"
check "[no active loop] exits 0 silently" "[[ $RC -eq 0 && -z \"\$OUT\" && -z \"\$ERR\" ]]"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
