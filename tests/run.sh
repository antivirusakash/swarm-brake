#!/usr/bin/env bash
cd "$(dirname "$0")/.." || exit 1
SB=bin/swarm-brake
pass=0; fail=0
export SB_STATE; SB_STATE=$(mktemp -d)
export SB_CONFIG=/dev/null SB_POLL=1 SB_WAIT=2 SB_LEASE=6 SB_FAKE_PRESSURE=1 SB_FAKE_SWAP=0

check() {
  case "$2" in
    !*) [[ "$3" != *"${2#!}"* ]] ;;
    "") [ -z "$3" ] ;;
    *)  [[ "$3" == *"$2"* ]] ;;
  esac && { pass=$((pass+1)); echo "ok   $1"; } || { fail=$((fail+1)); echo "FAIL $1"; echo "     want: ${2:-<empty>}"; echo "     got:  $3"; }
}
hook() { jq -nc --arg c "$1" --arg id "${2:-toolu_$RANDOM$RANDOM}" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_use_id:$id,tool_input:{command:$c,timeout:60000,description:"x"}}'; }
gate() { rm -rf "$SB_STATE/leases"; hook "$1" | "$SB" gate; }

check "script parses under /bin/bash" "ok" "$(/bin/bash -n "$SB" 2>&1 && echo ok)"

while IFS= read -r c; do check "heavy: $c" heavy "$($SB classify "$c")"; done <<'EOF'
for f in *.mp4; do ffmpeg -i "$f" x; done
if true; then npm run build; fi
npm run build:prod
bash -lc 'ffmpeg -i a b'
ls | xargs -n1 ffmpeg -i
docker compose -f x.yml up
yarn workspace web build
uv run remotion render
watch -n1 ffmpeg -i a b
echo $'\''; ffmpeg -i a b
echo \"; ffmpeg -i a b
npx remotion still A f.png
cd x && npm run build
FOO=1 ffmpeg -i a b
bash -c "xcodebuild -scheme X"
bash -c 'cd web && npm run build'
node node_modules/.bin/remotion render
timeout 600 npx remotion render
pnpm exec remotion render
npm --prefix web run build
xcrun xcodebuild -scheme X
sudo -u bob ffmpeg -i a b
echo hi; sleep 1 && npx playwright test
docker compose up -d
EOF
while IFS= read -r c; do check "light: $c" light "$($SB classify "$c")"; done <<'EOF'
cat engine/.remotion/x.log
grep -r ffmpeg src
git commit -m "npm run build"
git commit -m "fix; ffmpeg crash"
grep -E 'a|ffmpeg' src
ffprobe a.mp4
xcrun simctl list
docker compose ps
gradle-lint check
webpackish --x
EOF
check "light: heredoc body mentioning ffmpeg" light "$($SB classify $'cat > notes.md <<EOF\nrun ffmpeg -i a b later\nEOF')"
check "heavy: command after a heredoc" heavy "$($SB classify $'cat > n <<EOF\nhi\nEOF\nffmpeg -i a b')"
check "light: quoted heredoc delimiter" light "$($SB classify $'cat <<"EOF"\nffmpeg -i a b\nEOF\nls')"
check "heavy: here-string starts no heredoc" heavy "$($SB classify $'cat <<< hi\nffmpeg -i a b')"
check "heavy: <<EOF inside quotes starts no heredoc" heavy "$($SB classify $'echo "<<EOF"\nffmpeg -i a b')"
check "heavy: quote spanning lines" heavy "$($SB classify $'echo "a\nb"; ffmpeg -i a b')"
check "light: program name inside a multi-line string" light "$($SB classify $'git commit -m "a\nffmpeg -i x"')"

export SB_FAKE_MEM=80 SB_FAKE_LOAD=1 SB_FAKE_HEAVY=0
check "light command passes silently" "" "$(gate 'ls -la')"
check "heavy command with room passes silently" "" "$(gate 'npx remotion still A f.png')"
check "it takes a lease owned by a live process" "alive" "$(o=$(head -1 "$SB_STATE"/leases/* 2>/dev/null); kill -0 "${o:-x}" 2>/dev/null && echo alive)"
check "SB_FORCE prefix is not a bypass" '"deny"' "$(SB_FAKE_MEM=1 gate 'SB_FORCE=1 ffmpeg -i a b')"

check "codex cmd field is gated" '"deny"' "$(rm -rf "$SB_STATE/leases"; jq -nc '{tool_name:"exec_command",tool_input:{cmd:"ffmpeg -i a b",workdir:"/x"}}' | SB_FAKE_MEM=5 $SB gate)"
check "array command passes untouched" "" "$(jq -nc '{tool_name:"local_shell",tool_input:{command:["ffmpeg","-i","a"]}}' | SB_FAKE_MEM=5 $SB gate)"

tmpr=$(mktemp -d); ln -s "$(command -v sleep)" "$tmpr/dgtest-render"
rm -rf "$SB_STATE/leases"; sleep 1
hook "$tmpr/dgtest-render 5" | env -u SB_FAKE_HEAVY SB_NICE=7 SB_HEAVY_REGEX=dgtest-render $SB gate
"$tmpr/dgtest-render" 5 & rp=$!; sleep 2
check "watcher renices the new job" "7" "$(ps -o nice= -p $rp | tr -d ' ')"
check "watcher releases the lease" "0" "$(ls "$SB_STATE/leases" | wc -l | tr -d ' ')"
kill $rp 2>/dev/null; wait $rp 2>/dev/null
"$tmpr/dgtest-render" 8 & rp=$!; sleep 2
hook "$tmpr/dgtest-render 5" | env -u SB_FAKE_HEAVY SB_NICE=7 SB_HEAVY_REGEX=dgtest-render SB_MAX_HEAVY=5 $SB gate; sleep 2
check "watcher leaves a job that started before the grant" "0" "$(ps -o nice= -p $rp | tr -d ' ')"
check "and keeps holding the lease" "1" "$(ls "$SB_STATE/leases" | wc -l | tr -d ' ')"
kill $rp 2>/dev/null; wait $rp 2>/dev/null; rm -rf "$tmpr" "$SB_STATE/leases"; sleep 1

out=$(SB_FAKE_MEM=5 gate 'ffmpeg -i a b')
check "low memory denies" '"permissionDecision":"deny"' "$out"
check "deny says why" 'memory available 5%' "$out"
check "deny does not teach the agent the bypass" '!SB_FORCE' "$out"
check "low memory never touches light commands" "" "$(SB_FAKE_MEM=5 gate 'git status')"
check "high load denies" 'load 30 on' "$(SB_FAKE_LOAD=30 gate 'ffmpeg -i a b')"
check "critical pressure denies" 'critical' "$(SB_FAKE_PRESSURE=4 gate 'ffmpeg -i a b')"
check "slot cap denies" '2 heavy jobs already running' "$(SB_FAKE_HEAVY=2 gate 'ffmpeg -i a b')"
check "swap check is off by default" '!swap' "$(SB_FAKE_SWAP=99 gate 'ffmpeg -i a b')"
check "swap check when set" 'swap 99%' "$(SB_SWAP_MAX=90 SB_FAKE_SWAP=99 gate 'ffmpeg -i a b')"

memf=$SB_STATE/mem; echo 5 > "$memf"; ( sleep 2; echo 80 > "$memf" ) &
t0=$(date +%s)
out=$(rm -rf "$SB_STATE/leases"; hook 'ffmpeg -i a b' | env -u SB_FAKE_MEM SB_FAKE_MEM_FILE="$memf" SB_WAIT=10 $SB gate)
check "gate waits, then passes" "" "$out"
check "gate really waited" "yes" "$([ $(( $(date +%s) - t0 )) -ge 2 ] && echo yes || echo no)"

rm -rf "$SB_STATE/leases"
hook 'ffmpeg -version' toolu_fast | $SB gate >/dev/null
check "lease named by tool_use_id" "yes" "$([ -f "$SB_STATE/leases/toolu_fast" ] && echo yes)"
jq -nc '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_use_id:"toolu_fast"}' | $SB done
check "done hook stops it counting within 3 s" "free" "$(sleep 3.2; hook 'ffmpeg -i a b' | SB_MAX_HEAVY=1 $SB gate | grep -q deny && echo held || echo free)"
check "done hook with garbage input exits 0" "0" "$(echo junk | $SB done; echo $?)"

tmpr=$(mktemp -d); ln -s "$(command -v sleep)" "$tmpr/dgtest-render"; ln -s "$(command -v sleep)" "$tmpr/dgtest-other"
rm -rf "$SB_STATE/leases"; sleep 1
hook "$tmpr/dgtest-render 5" toolu_claim | env -u SB_FAKE_HEAVY SB_HEAVY_REGEX='dgtest-render|dgtest-other' SB_MAX_HEAVY=5 $SB gate
"$tmpr/dgtest-other" 6 & op=$!; sleep 2
check "ungated heavy work does not take the slot" "yes" "$([ -f "$SB_STATE/leases/toolu_claim" ] && echo yes)"
kill $op 2>/dev/null; wait $op 2>/dev/null; rm -rf "$tmpr" "$SB_STATE/leases"; sleep 1

rm -rf "$SB_STATE/leases"
hook 'ffmpeg -i a b' toolu_twice | SB_MAX_HEAVY=1 $SB gate >/dev/null
check "a second gate for the same call is let through" "" "$(hook 'ffmpeg -i a b' toolu_twice | SB_MAX_HEAVY=1 $SB gate)"
rm -rf "$SB_STATE/leases"; sleep 1

ln -s "999999 $(date +%s) 1" "$SB_STATE/lock"
t0=$(date +%s); out=$(hook 'ffmpeg -i a b' | $SB gate)
check "dead holder's lock is broken" "" "$out"
check "and quickly" "yes" "$([ $(( $(date +%s) - t0 )) -lt 2 ] && echo yes)"
rm -rf "$SB_STATE/leases"

ln -s "$$ $(date +%s) 1" "$SB_STATE/lock"
hook 'ffmpeg -i a b' | $SB gate >/dev/null & gp=$!; sleep 3
check "a live holder's lock is not broken" "$$" "$(readlink "$SB_STATE/lock" | cut -d' ' -f1)"
check "the waiting gate never removed it" "yes" "$(kill -0 $gp 2>/dev/null && echo yes)"
wait $gp
rm -f "$SB_STATE/lock"

rm -rf "$SB_STATE/leases"
a=$(hook 'ffmpeg -i a b' | SB_MAX_HEAVY=1 $SB gate)
b=$(hook 'ffmpeg -i c d' | SB_MAX_HEAVY=1 $SB gate)
check "first gate takes the slot" "" "$a"
check "second gate sees the lease" 'already running' "$b"
rm -rf "$SB_STATE/leases"; mkdir -p "$SB_STATE/leases"; echo 999999 >"$SB_STATE/leases/1.1"
check "lease of a dead agent is ignored" "" "$(hook 'ffmpeg -i a b' | SB_MAX_HEAVY=1 $SB gate)"

rm -rf "$SB_STATE/leases"; ln -s "$$ $(( $(date +%s) - 60 )) 1" "$SB_STATE/lock"
t0=$(date +%s); out=$(hook 'ffmpeg -i a b' | $SB gate)
check "stale lock is broken" "" "$out"
check "stale lock costs under 3s" "yes" "$([ $(( $(date +%s) - t0 )) -lt 3 ] && echo yes || echo no)"

out=$(SB_MODE=observe SB_FAKE_MEM=5 gate 'ffmpeg -i a b')
check "observe mode blocks nothing" "" "$out"
lastev() { tail -1 "$SB_STATE"/events/*.log 2>/dev/null; }
check "observe mode records what it would do" "verdict=would_hold why=mem" "$(lastev)"

check "grep -c with a quoted heavy word is light" "light" "$($SB classify 'grep -c "ffmpeg" log.txt')"
check "rg -c with a quoted heavy word is light" "light" "$($SB classify 'rg -c "npm run build" .')"
check "bash -c with an ANSI-C quoted body is read" "heavy" "$($SB classify "bash -c \$'ffmpeg -i a b'")"
check "sh -lc body is still read" "heavy" "$($SB classify "sh -lc 'npx remotion render x'")"
check "fake readings in the config file are ignored" "verdict=would_hold" "$(cf=$(mktemp); echo SB_FAKE_MEM=100 >"$cf"; SB_MODE=observe SB_CONFIG=$cf SB_FAKE_MEM=5 gate 'ffmpeg -i a b' >/dev/null; rm -f "$cf"; lastev)"
check "an unknown mode acts as enforce" "deny" "$(SB_MODE=obsrve SB_FAKE_MEM=1 gate 'ffmpeg -i a b')"
evcount() { cat "$SB_STATE"/events/*.log 2>/dev/null | wc -l | tr -d ' '; }
n0=$(evcount); gate 'ls -la' >/dev/null; gate 'git status' >/dev/null
check "light commands write no events" "$n0" "$(evcount)"
gate 'ffmpeg -i a b' >/dev/null; enf=$(lastev)
SB_MODE=observe gate 'ffmpeg -i a b' >/dev/null; obs=$(lastev)
keys() { printf '%s' "$1" | tr ' ' '\n' | cut -d= -f1 | tr '\n' ' '; }
check "observe and enforce write the same fields" "$(keys "$enf")" "$(keys "$obs")"
check "gate event names the session and folder" "sess=sess-1 agent=- where=proj#" "$(jq -nc --arg c 'ffmpeg -i a b' '{tool_name:"Bash",tool_use_id:"toolu_w",session_id:"sess-1",cwd:"/Users/x/proj",tool_input:{command:$c}}' | $SB gate; lastev)"
check "the full folder path is not stored" '!/Users/x' "$(lastev)"
check "denied call is recorded" "verdict=denied why=mem" "$(SB_FAKE_MEM=1 gate 'ffmpeg -i a b' >/dev/null; lastev)"
check "held call is recorded with its wait" "verdict=held why=mem wait=" "$(memf2=$SB_STATE/mem2; echo 5 >$memf2; ( sleep 1.5; echo 80 >$memf2 ) & rm -rf "$SB_STATE/leases"; hook 'ffmpeg -i a b' | env -u SB_FAKE_MEM SB_FAKE_MEM_FILE=$memf2 SB_WAIT=10 $SB gate >/dev/null; lastev)"
check "URLs are not stored" "key=ffmpeg verdict" "$(gate 'ffmpeg -i https://u:pw@cdn.example.com/a.mp4?sig=x out.mp4' >/dev/null; lastev)"
check "long tokens are not stored" "key=whisper+*+x " "$(gate 'whisper sk_live_0123456789abcdefghij x' >/dev/null; lastev)"
check "SB_LOG_CMD=off keeps the program only" "key=ffmpeg+" "$(SB_LOG_CMD=off gate 'ffmpeg -i secret.mp4 o' >/dev/null; lastev)"
check "a flag's value is not stored" "key=whisper verdict" "$(gate 'whisper --hf-token hf_abc123SHORT audio.wav' >/dev/null; lastev)"
check "a short token is not stored" "key=whisper+* " "$(gate 'whisper hf_abc123SHORT' >/dev/null; lastev)"
check "argument paths are not stored" "key=ffmpeg verdict" "$(gate 'ffmpeg -i /Users/akash/Clients/AcmeCorp/raw.mov out.mp4' >/dev/null; lastev)"
check "a file name is not stored" "key=remotion+still+* " "$(gate 'npx remotion still AcmeLaunch.tsx out.png' >/dev/null; lastev)"
check "subcommands are kept" "key=npm+run+build " "$(gate 'npm run build' >/dev/null; lastev)"
check "no line is over 400 bytes" "0" "$(awk 'length > 400' "$SB_STATE"/events/*.log | wc -l | tr -d ' ')"
hook 'ffmpeg -i a b' toolu_d | $SB gate >/dev/null
for i in 1 2; do jq -nc '{hook_event_name:"PostToolUseFailure",tool_use_id:"toolu_d"}' | $SB done; done
check "done is recorded once, with the failure" "1" "$(grep -c 'ev=done .*call=toolu_d .*status=fail' "$SB_STATE"/events/*.log)"
jq -nc '{hook_event_name:"PostToolUse",tool_use_id:"toolu_light"}' | $SB done
check "done of an ungated call writes nothing" "0" "$(grep -c 'call=toolu_light' "$SB_STATE"/events/*.log)"

tmpj=$(mktemp -d); printf '#!/bin/sh\nsleep 20 &\nsleep 3\n' >"$tmpj/dgjob-render"; chmod +x "$tmpj/dgjob-render"
rm -rf "$SB_STATE/leases"; sleep 1
hook "$tmpj/dgjob-render" toolu_job | env -u SB_FAKE_HEAVY SB_HEAVY_REGEX=dgjob-render $SB gate
"$tmpj/dgjob-render" & sleep 6
check "watcher records the job start" "ev=start mode=enforce call=toolu_job" "$(grep 'ev=start' "$SB_STATE"/events/*.log | tail -1)"
check "watcher records the end with duration" "call=toolu_job pid=" "$(grep 'ev=end' "$SB_STATE"/events/*.log | tail -1)"
check "duration is within 2 s of the real 3 s" "yes" "$(grep 'ev=end' "$SB_STATE"/events/*.log | tail -1 | grep -qE 'dur=[345] ' && echo yes || grep 'ev=end' "$SB_STATE"/events/*.log | tail -1)"
orph=$(grep 'ev=orphan' "$SB_STATE"/events/*.log | tail -1)
check "the orphan it left is recorded" "call=toolu_job pids=" "$orph"
check "and it is the real leftover process" "sleep" "$(ps -o command= -p "$(echo "$orph" | sed 's/.*pids=//; s/,.*//')" 2>/dev/null)"
pkill -f "^sleep 20$" 2>/dev/null
ln -s "$(command -v sleep)" "$tmpj/dgjob-one"; rm -rf "$SB_STATE/leases"
hook "dgjob-one 2" toolu_one | env -u SB_FAKE_HEAVY SB_HEAVY_REGEX=dgjob-one $SB gate
"$tmpj/dgjob-one" 2 & sleep 4
check "a one-process job is followed to its end" "call=toolu_one pid=" "$(grep 'ev=end' "$SB_STATE"/events/*.log | tail -1)"
check "reniced records whether it was reniced" "reniced=1" "$(grep 'ev=end' "$SB_STATE"/events/*.log | tail -1)"
rm -rf "$tmpj"
check "machine readings are written, at most one a minute" "1 0" "$(grep -h 'ev=pulse' "$SB_STATE"/events/*.log | sed 's/^ts=\([0-9]*\).*/\1/' | awk '{ m[int($1 / 60)]++ } END { for (k in m) { n++; if (m[k] > 1) d++ } print (n > 0), d + 0 }')"

fx=$(mktemp -d); mkdir -p "$fx/events"
cat >"$fx/events/2026-10-14.log" <<'EOF'
ts=1791954600 t=10:40:00 v=1 ev=pulse mode=observe mem=48 press=1 load=9.1 ncpu=10 swap=40 heavy=0 ungated=0 claude=11 node=44
ts=1791955018 t=10:46:58 v=1 ev=gate mode=observe call=toolu_A sess=3c079921-aaaa agent=- where=marketing-os#9af1 key=remotion+still+* verdict=room why=- wait=0 mem=31 press=2 load=14.2 ncpu=10 swap=55 heavy=1
ts=1791955019 t=10:46:59 v=1 ev=start mode=observe call=toolu_A pid=50110 prog=remotion lag=1
ts=1791955022 t=10:47:02 v=1 ev=gate mode=observe call=toolu_B sess=3c079921-aaaa agent=- where=marketing-os#9af1 key=remotion+still+* verdict=would_hold why=heavy,load wait=0 mem=29 press=2 load=18.4 ncpu=10 swap=55 heavy=2
ts=1791955023 t=10:47:03 v=1 ev=start mode=observe call=toolu_B pid=50300 prog=remotion lag=1
ts=1791955380 t=10:53:00 v=1 ev=pulse mode=observe mem=6 press=4 load=26.4 ncpu=10 swap=77 heavy=4 ungated=2 claude=11 node=44
ts=1791955390 t=10:53:10 v=1 ev=turn mode=observe sess=9be1d2aa-bbbb agent=- where=map-csv#11c0
ts=1791955540 t=10:55:40 v=1 ev=end mode=observe call=toolu_A pid=50110 dur=521 peak_mb=3994 procs=14 reniced=0
ts=1791955540 t=10:55:40 v=1 ev=orphan mode=observe call=toolu_A pids=51234,51240
ts=1791955632 t=10:57:12 v=1 ev=reap mode=observe roots=51234 procs=3 rss_mb=2310
ts=1791955700 t=10:58:20 v=1 ev=gate mode=enforce call=toolu_C sess=3c079921-aaaa agent=- where=marketing-os#9af1 key=remotion+still+* verdict=held why=heavy wait=35 mem=40 press=1 load=12 ncpu=10 swap=50 heavy=1
ts=1791955800 t=11:00:00 v=1 ev=gate mode=enforce call=toolu_D sess=3c079921-aaaa agent=- where=marketing-os#9af1 key=remotion+still+* verdict=denied why=mem wait=90 mem=5 press=4 load=12 ncpu=10 swap=50 heavy=2
ts=1791955801 t=11:00:01 v=1 ev=gate mode=enforce call=toolu_E sess=3c079921-aaaa agent=- where=marketing-os#9af1 key=ffmpeg verdict=failopen why=- wait=15 mem=90 press=1 load=1 ncpu=10 swap=50 heavy=0
ts=1791955802 t=11:00:02 v=1 ev=pulse mode=enforce mem=50 press=1 load=3 swap=1 heavy=0
garbage line
EOF
rep=$(TZ=Asia/Kolkata SB_STATE=$fx $SB report --days 100000 2>&1 | tr -s " ")
check "report counts gated calls by mode" "heavy calls gated 2 3" "$rep"
check "report counts starts without room" "heavy starts while there was no room 1 (50%)" "$rep"
check "report counts distress minutes" "distress minutes 1 (30.0/h)" "$rep"
check "report traces the reaped orphan to its call" "1, 2310 MB (1 traced)" "$rep"
check "report lists job sizes" "remotion 1 521s" "$rep"
check "report skips malformed lines" "2 malformed lines skipped" "$rep"
rca=$(TZ=Asia/Kolkata SB_STATE=$fx $SB report --at '2026-10-14 10:55' 2>&1)
check "timeline shows the minute the machine was in trouble" "10:53:00    6%  critical  2.64" "$rca"
check "timeline lists the jobs running then" "10:46:59  10:55:40    521s  3994 MB  remotion+still+*" "$rca"
check "timeline says which call left the orphan" "left by toolu_A (session 3c079921, marketing-os#9af1)" "$rca"
check "timeline names the bystander session" "9be1d2aa  map-csv#11c0" "$rca"
check "a failopen with room is not counted as no room" "heavy starts while there was no room 1 (50%) 0 (0%)" "$rep"
check "denied calls do not raise the peak" "heavy jobs at once, peak 4 2 " "$rep"
check "a line with no core count is skipped, not fatal" "2 malformed lines skipped" "$rep"
check "report with no events says so" "no events" "$(SB_STATE=$(mktemp -d) $SB report)"
check "a missing value is refused, not looped on" "usage" "$(SB_STATE=$fx timeout 5 $SB report --days 2>&1)"
check "and fails" "1" "$(SB_STATE=$fx timeout 5 $SB report --at >/dev/null 2>&1; echo $?)"
mkdir -p "$fx/mid/events"; echo "ts=1792002610 t=00:00:10 v=1 ev=pulse mode=observe mem=7 press=1 load=30 ncpu=10 swap=1 heavy=3 ungated=0 claude=1 node=1" >"$fx/mid/events/2026-10-15.log"
check "a window across midnight reads the next day" "00:00:10" "$(TZ=Asia/Kolkata SB_STATE=$fx/mid $SB report --at '2026-10-14 23:55' 2>&1)"
check "a bad time is refused" "cannot read time" "$(SB_STATE=$fx $SB report --at 'yesterday-ish' 2>&1)"
rm -rf "$fx"

cfg=$SB_STATE/cfg; printf 'SB_MEM_MIN=90\nSB_WAIT=abc\n' > "$cfg"
check "config file is read" 'min 90%' "$(SB_CONFIG=$cfg SB_WAIT=1 gate 'ffmpeg -i a b')"
check "env wins over config" '!min 90%' "$(SB_CONFIG=$cfg SB_MEM_MIN=10 gate 'ffmpeg -i a b')"
check "bad number falls back to default" "" "$(SB_POLL=abc SB_WAIT=xyz gate 'ffmpeg -i a b')"
printf 'SB_MODE=observe\r\n' >"$cfg"
check "CRLF config line still works" "" "$(SB_CONFIG=$cfg SB_FAKE_MEM=1 gate 'ffmpeg -i a b')"
printf 'SB_X;touch %s/pwned;SB_Y=1\n' "$SB_STATE" >"$cfg"
SB_CONFIG=$cfg gate 'ls' >/dev/null
check "config line cannot run code" "safe" "$([ -e "$SB_STATE/pwned" ] && echo pwned || echo safe)"

check "garbage input passes" "" "$(echo 'not json' | $SB gate)"
check "empty input passes" "" "$(: | $SB gate)"
check "SB_DISABLE=1 passes" "" "$(SB_DISABLE=1 SB_FAKE_MEM=1 gate 'ffmpeg -i a b')"
check "missing tools (no jq, empty PATH) passes" "" "$(hook 'ffmpeg -i a b' | SB_FAKE_MEM=1 PATH=/var/empty /bin/bash "$SB" gate 2>/dev/null)"
broken=$(mktemp -d); mkdir -p "$broken/bin"; printf 'case x in\n' > "$broken/bin/swarm-brake"
cmdline=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' hooks/hooks.json)
rc=$(hook 'ls' | CLAUDE_PLUGIN_ROOT=$broken bash -c "$cmdline" >/dev/null 2>&1; echo $?)
check "a crashing script still exits 0 through hooks.json" "0" "$rc"
rm -rf "$broken"

tmp=$(mktemp -d); ln -s "$(command -v sleep)" "$tmp/chrome-headless-shell"
export SB_REAP_REGEX="$tmp/chrome-headless-shell"
( "$tmp/chrome-headless-shell" 300 </dev/null >/dev/null 2>&1 & ) ; sleep 0.5
pid=$(pgrep -f "$tmp/chrome-headless-shell")
check "orphan exists with parent 1" " 1" " $(ps -o ppid= -p "$pid" | tr -d ' ')"
SB_REAP_AGE=0 $SB reap </dev/null; sleep 0.5
check "reap kills the orphan" "gone" "$(kill -0 "$pid" 2>/dev/null && echo alive || echo gone)"
( "$tmp/chrome-headless-shell" 300 </dev/null >/dev/null 2>&1 & ) ; sleep 0.5
pid=$(pgrep -f "$tmp/chrome-headless-shell")
SB_REAP_AGE=3600 $SB reap </dev/null; sleep 0.5
check "reap spares young orphans" "alive" "$(kill -0 "$pid" 2>/dev/null && echo alive || echo gone)"
kill "$pid" 2>/dev/null
sleep 300 </dev/null >/dev/null 2>&1 & keep=$!
SB_REAP_AGE=0 SB_REAP_REGEX="sleep 300" $SB reap </dev/null; sleep 0.5
check "reap spares processes that still have a parent" "alive" "$(kill -0 "$keep" 2>/dev/null && echo alive || echo gone)"
kill $keep 2>/dev/null; wait $keep 2>/dev/null; rm -rf "$tmp" "$SB_STATE"

echo; echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
