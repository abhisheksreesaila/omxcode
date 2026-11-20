#!/bin/bash
# D-7876: omx's M7f picture runs (real model) in a loop, every pass's logs and full stderr kept
cd /home/abhisheksreesaila/Projects/mxapp/mojo-ui-g77
for i in $(seq 1 ${1:-3}); do
  CUDA_DEVICE_ORDER=PCI_BUS_ID MOJOUI_HEADLESS=1 pixi run python scripts/g77_m7f_run.py shots > build/g77/crashloop/${SHOTS_TAG:-shots}-$i.txt 2>&1
  mkdir -p build/g77/crashloop/${SHOTS_TAG:-shots}-$i; cp build/g77/m7f/shot-*.log build/g77/m7f/shot-*.err build/g77/crashloop/${SHOTS_TAG:-shots}-$i/ 2>/dev/null
  grep -h -- "--- exit" build/g77/m7f/shot-*.log | sed "s/^/pass $i: /"
done
