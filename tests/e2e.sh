#!/usr/bin/env bash
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
command -v claude >/dev/null || { echo "claude not on PATH"; exit 1; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
printf '#!/bin/sh\nsleep 2\necho "fake ffmpeg ran nice=$(ps -o nice= -p $$ | tr -d " ")"\n' >"$W/bin/ffmpeg"; chmod +x "$W/bin/ffmpeg"
ln -s "$(command -v sleep)" "$W/bin/e2e-render"
pass=0; fail=0
check() { if [[ "$3" == *"$2"* ]]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; echo "     want: $2"; echo "     got:  ${3:0:400}"; fi; }
agent() {
  local dir=$1 prompt=$2; shift 2
  [ $# -gt 0 ] || set -- --permission-mode bypassPermissions
  ( cd "$W" && PATH="$W/bin:$PATH" SB_STATE="$dir" SB_CONFIG=/dev/null \
    timeout 240 claude -p --settings '{"enabledPlugins":{"swarm-brake@swarm-brake":false}}' --plugin-dir "$ROOT" --model haiku "$@" "$prompt" </dev/null 2>&1 )
}

echo "== 1. no room: the agent is told why and stops"
out=$(SB_FAKE_MEM=5 SB_WAIT=3 SB_POLL=1 agent "$W/s1" "Run exactly this bash command once and do not retry or change it: ffmpeg -i in.mp4 out.mp4 . Then quote any hook message verbatim.")
check "agent saw the reason" "memory available 5%" "$out"
check "the denial is recorded" "verdict=denied why=mem" "$(cat "$W"/s1/events/*.log 2>/dev/null)"
[[ "$out" == *"fake ffmpeg ran"* ]] && { fail=$((fail+1)); echo "FAIL command ran anyway"; }

echo "== 2. room: the command runs, at nice 10"
out=$(SB_FAKE_HEAVY=0 SB_MEM_MIN=1 SB_LOAD_MAX=999 agent "$W/s2" "Run exactly this bash command once and do not change it: ffmpeg -i in.mp4 out.mp4 . Reply with its raw output only.")
check "command ran" "fake ffmpeg ran" "$out"
check "at lower priority" "nice=10" "$out"

echo "== 3. parallel background renders queue for one slot"
SB_MAX_HEAVY=1 SB_MEM_MIN=1 SB_LOAD_MAX=999 SB_POLL=1 SB_HEAVY_REGEX='e2e-render' agent "$W/s3" \
  "Start these three bash commands at the same time, each as its own background Bash call (run_in_background), in one message: 'e2e-render 8', 'e2e-render 8', 'e2e-render 8'. Then wait until all three have finished and say done." >/dev/null
check "later renders waited for the slot" "verdict=held why=heavy" "$(cat "$W"/s3/events/*.log 2>/dev/null)"
check "each render's end was recorded" "3" "$(cat "$W"/s3/events/*.log 2>/dev/null | grep -c 'ev=end ')"
check "the gate event names the session" "sess=" "$(grep -m1 'ev=gate' "$W"/s3/events/*.log 2>/dev/null | grep -v 'sess=-')"

echo "== 4. orphaned headless browser is cleaned up when the agent stops"
ln -s "$(command -v sleep)" "$W/bin/chrome-headless-shell"
( "$W/bin/chrome-headless-shell" 600 </dev/null >/dev/null 2>&1 & ); sleep 0.5
pid=$(pgrep -f "$W/bin/chrome-headless-shell 600")
SB_REAP_AGE=0 SB_REAP_REGEX="$W/bin/chrome-headless-shell" agent "$W/s4" "Reply with the word ok." >/dev/null; sleep 1
check "orphan reaped by the Stop hook" "gone" "$(kill -0 "$pid" 2>/dev/null && echo alive || echo gone)"
kill "$pid" 2>/dev/null

echo "== 5. normal permission mode: an allow rule still matches the gated command"
out=$(SB_FAKE_HEAVY=0 SB_MEM_MIN=1 SB_LOAD_MAX=999 agent "$W/s5" "Run exactly this bash command once, unchanged: ffmpeg -i in.mp4 out.mp4 . Reply with its raw output only, or the exact error if it did not run." \
  --permission-mode default '--allowedTools=Bash(ffmpeg:*)')
check "allowed command ran without a prompt" "fake ffmpeg ran" "$out"

echo "== 6. a command that exits at once frees its slot when the call ends"
SB_FAKE_HEAVY=0 SB_MEM_MIN=1 SB_LOAD_MAX=999 SB_HEAVY_REGEX='e2e-render' agent "$W/s6" "Run exactly this bash command once, unchanged: e2e-render 0 . Then reply with the word ok." >/dev/null
check "no lease left behind" "0" "$(ls "$W/s6/leases" 2>/dev/null | wc -l | tr -d ' ')"
check "a lease was taken at all" "yes" "$([ -d "$W/s6/leases" ] && echo yes)"

echo; echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
