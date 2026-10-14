#!/usr/bin/env bash
# Usage: tests/bench.sh [rounds] [jobs] [mb] [secs]
# Starts N jobs at once (each holds MB of memory and spins one core for SECS),
# with and without the gate, alternating, and prints one row per round.
cd "$(dirname "$0")/.." || exit 1
SB=$PWD/bin/swarm-brake
ROUNDS=${1:-5} JOBS=${2:-8} MB=${3:-400} SECS=${4:-8}
W=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT
mkdir -p "$W/bin"
cat >"$W/bin/sbbench-job" <<EOF
#!/bin/sh
exec python3 -c 'import os,time,sys
b=bytearray(int(sys.argv[1])<<20)
for i in range(0,len(b),1<<20): b[i:i+(1<<20)]=os.urandom(1<<20)
t=time.time()
while time.time()-t<float(sys.argv[2]): pass' "\$@"
EOF
chmod +x "$W/bin/sbbench-job"
export SB_CONFIG=/dev/null SB_MAX_HEAVY=2 SB_WAIT=600 SB_POLL=1 SB_HEAVY_REGEX='sbbench-job' SB_FAKE_HEAVY=0

sampler() {
  python3 - "$1" <<'EOF'
import os, subprocess, sys, time
out = open(sys.argv[1], "w")
while not os.path.exists(sys.argv[1] + ".stop"):
    t = time.perf_counter(); subprocess.run(["/usr/bin/true"]); probe = (time.perf_counter() - t) * 1000
    ps = subprocess.run(["ps", "-axo", "pid=,ppid=,rss=,command="], capture_output=True, text=True).stdout
    found = [l.split(None, 3) for l in ps.splitlines() if " -c import os,time,sys" in l]
    parents = {r[1] for r in found}
    rows = [r[2:] for r in found if r[0] not in parents]
    lvl = subprocess.run(["sysctl", "-n", "kern.memorystatus_level"], capture_output=True, text=True).stdout.strip() or "-1"
    out.write(f"{len(rows)} {sum(int(r[0]) for r in rows)//1024} {lvl} {probe:.1f}\n"); out.flush()
    time.sleep(0.2)
EOF
}

run() {
  local mode=$1 tag=$2 s=$W/$2.samples t0 t1
  SB_STATE=$W/state-$tag; export SB_STATE
  sampler "$s" & local smp=$!
  t0=$(python3 -c 'import time;print(time.time())')
  for i in $(seq 1 "$JOBS"); do
    (
      if [ "$mode" = with ]; then
        o=$(jq -nc --arg c "sbbench-job $MB $SECS" --arg id "b$i" '{tool_name:"Bash",tool_use_id:$id,tool_input:{command:$c}}' |
          SB_FAKE_MEM=80 SB_FAKE_LOAD=0 "$SB" gate)
        case "$o" in *'"deny"'*) echo deny >>"$W/$tag.denied"; exit ;; esac
      fi
      "$W/bin/sbbench-job" "$MB" "$SECS"
      [ "$mode" = with ] && jq -nc --arg id "b$i" '{tool_name:"Bash",tool_use_id:$id}' | "$SB" done >/dev/null
    ) &
  done
  wait $(jobs -p | grep -v "^$smp\$") 2>/dev/null
  t1=$(python3 -c 'import time;print(time.time())')
  touch "$s.stop"; wait $smp 2>/dev/null
  python3 - "$s" "$mode" "$t0" "$t1" "$(cat "$W/$tag.denied" 2>/dev/null | wc -l | tr -d ' ')" <<'EOF'
import sys
rows = [list(map(float, l.split())) for l in open(sys.argv[1]) if l.strip()]
p = sorted(r[3] for r in rows)
print(f"{sys.argv[2]:<8}  jobs at once {max(r[0] for r in rows):.0f}  job memory peak {max(r[1] for r in rows):5.0f} MB"
      f"  lowest free mem {min(r[2] for r in rows):3.0f}%  probe p95 {p[int(len(p)*0.95)]:6.1f} ms  max {p[-1]:6.1f} ms"
      f"  wall {float(sys.argv[4])-float(sys.argv[3]):5.1f} s  denied {sys.argv[5]}")
EOF
}

echo "$(date '+%F %T')  $(sysctl -n hw.memsize | awk '{print $1/1073741824}') GB, $(sysctl -n hw.ncpu) cores, load $(sysctl -n vm.loadavg | awk '{print $2}'), $JOBS jobs x $MB MB x $SECS s, 2 slots"
for r in $(seq 1 "$ROUNDS"); do
  run without "a$r"
  run with "b$r"
done
