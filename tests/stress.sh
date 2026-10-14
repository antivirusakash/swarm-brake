#!/usr/bin/env bash
cd "$(dirname "$0")/.." || exit 1
SB=$PWD/bin/swarm-brake
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"; ln -s "$(command -v sleep)" "$W/bin/dgstress-render"
export SB_STATE=$W/state SB_CONFIG=/dev/null SB_MAX_HEAVY=2 SB_WAIT=80 SB_POLL=1 \
  SB_FAKE_MEM=80 SB_FAKE_LOAD=0 SB_HEAVY_REGEX='dgstress-render'
one() {
  local out
  out=$(jq -nc --arg c "$W/bin/dgstress-render 6" '{tool_name:"Bash",tool_input:{command:$c}}' | "$SB" gate)
  case "$out" in *'"deny"'*) echo deny >>"$W/denied"; return ;; esac
  "$W/bin/dgstress-render" 6
}
( while :; do pgrep -f "^$W/bin/dgstress-render 6\$" | wc -l | tr -d ' ' >>"$W/samples"; sleep 0.03; done ) & smp=$!
t0=$(date +%s)
for i in 1 2 3 4 5 6 7 8; do one $i & done
wait $(jobs -p | grep -v "^$smp\$") 2>/dev/null
kill $smp 2>/dev/null; wait $smp 2>/dev/null
max=$(sort -n "$W/samples" | tail -1); denied=$(cat "$W/denied" 2>/dev/null | wc -l | tr -d ' ')
echo "8 jobs of 6 s, 2 slots: max alive at once $max, denied ${denied:-0}, wall $(( $(date +%s) - t0 )) s (ideal 24 s)"
ok1=0; [ "$max" -le 2 ] && [ "${denied:-0}" = 0 ] && ok1=1

ok2=1
for run in 1 2 3 4 5; do
  S=$W/race$run; mkdir -p "$S"
  for i in $(seq 1 16); do
    ( o=$(jq -nc --arg id "r$i" '{tool_name:"Bash",tool_use_id:$id,tool_input:{command:"dgstress-render 1"}}' |
        SB_STATE=$S SB_MAX_HEAVY=1 SB_FAKE_HEAVY=0 SB_WAIT=3 "$SB" gate)
      [ -z "$o" ] && echo x >>"$S/allowed" ) &
  done; wait
  n=$(wc -l <"$S/allowed" | tr -d ' '); echo "16 gates, 1 slot, run $run: let through $n"
  [ "$n" = 1 ] || ok2=0
done
[ $ok1 = 1 ] && [ $ok2 = 1 ]
