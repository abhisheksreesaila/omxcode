#!/bin/bash
# D-7876: the M7E stage sequence in P parallel loops of N runs each (more preemption and CPU migration); TAGP names the batch.
# Extra env (e.g. GLIBC_TUNABLES) passes through.
cd /home/abhisheksreesaila/Projects/mxapp/mojo-ui-g77
P=${1:-12}; N=${2:-5}; TAGP=${3:-par}
for k in $(seq 1 $P); do pixi run python build/g77/crashloop/loop.py $N $TAGP$k > build/g77/crashloop/$TAGP$k.txt 2>&1 & done
wait
cat build/g77/crashloop/$TAGP*.txt | grep -E "clean;" 
python3 - "$TAGP" <<'PY'
import json, glob, sys
runs = [x for f in glob.glob(f"build/g77/crashloop/{sys.argv[1]}*-summary.json") for x in json.load(open(f)) if x["kind"] == "run"]
bad = [x for x in runs if x["rc"] != 0]
print(sys.argv[1], f"{len(runs) - len(bad)}/{len(runs)} sequences clean; crashes (rc -11): {sum(1 for x in bad if x['rc'] == -11)}; other: {[x['rc'] for x in bad if x['rc'] != -11]}")
PY
