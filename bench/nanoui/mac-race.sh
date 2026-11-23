#!/usr/bin/env bash
# Goal 80 M7: the race on the owner's Mac over SSH (no window): nanoui's own Metal hillclimb against scenes_metal.mojo on
# gpu2d's Metal backend, alternated 3 times; then test_gpu2d_metal and test_gpu2d_metal_shadow. Prints NANOUI RESULT / OMX
# RESULT lines (each side's run with the lowest median per scene and run) and the tests' last lines. Everything lives in ~/omxcode-g80 there; the pixi
# environment is another checkout's, used read-only (MAC_ENV_DIR). MAC_SSH (user@host), MAC_SSH_KEY.
set -euo pipefail
cd "$(dirname "$0")/../.."
host=${MAC_SSH:?set MAC_SSH=user@host}; key=${MAC_SSH_KEY:-$HOME/.ssh/edx_mac}; envd=${MAC_ENV_DIR:-omxcode-g54}
ssh_=(ssh -i "$key" -o BatchMode=yes -o ConnectTimeout=15 "$host")
tar -czf build/g80/mac-src.tar.gz --exclude=__pycache__ mojoui themes vendor fonts tests bench
"${ssh_[@]}" "mkdir -p omxcode-g80/src"
scp -q -i "$key" build/g80/mac-src.tar.gz "$host:omxcode-g80/"
"${ssh_[@]}" bash -s -- "$envd" <<'REMOTE'
set -euo pipefail
envd=$HOME/$1; cd ~/omxcode-g80; export PATH=$HOME/.pixi/bin:$PATH
rm -rf src && mkdir src && tar -xzf mac-src.tar.gz -C src
[ -x zig/zig ] || { mkdir -p zig && curl -fsSL https://ziglang.org/download/0.17.0/zig-aarch64-macos-0.17.0.tar.xz | tar xJ -C zig --strip-components 1; }
[ -d nanoui/.git ] || git clone -q https://github.com/justrach/nanoui
(cd nanoui && git checkout -q --force cfe6000 && cp ../src/bench/nanoui/metalrun.zig hillclimb/src/metal_run.zig && cd hillclimb && ~/omxcode-g80/zig/zig build -Doptimize=ReleaseFast > ~/omxcode-g80/zig.log 2>&1) || { tail -15 zig.log; exit 1; }
F="-Xlinker -lobjc -Xlinker -framework -Xlinker Metal -Xlinker -framework -Xlinker Foundation -Xlinker -framework -Xlinker IOSurface"
m() { (cd src && pixi run --frozen --manifest-path "$envd/pixi.toml" bash -c "cd ~/omxcode-g80/src && mojo build -O3 -I . $1 -o ../$2 $F") > $2.log 2>&1 || { grep -E "error" $2.log | head -8; exit 1; }; }
m bench/nanoui/scenes_metal.mojo omxmetal; m tests/test_gpu2d_metal.mojo tmetal; m tests/test_gpu2d_metal_shadow.mojo tshadow
mkdir -p shots; S=boxes,text,scroll,list,dashboard
x() { pixi run --frozen --manifest-path "$envd/pixi.toml" bash -c "cd ~/omxcode-g80/src && $*"; }
for k in 1 2 3; do
  nanoui/hillclimb/zig-out/bin/hillclimb --only nanoui --no-history --scene $S 2>&1 | grep "NANOUI RESULT" | sed "s/^/$k /"
  x "HC_SHOT=$HOME/omxcode-g80/shots ../omxmetal" 2>&1 | grep "OMX RESULT" | sed "s/^/$k /"
done
for t in tshadow tmetal; do echo "== $t"; x "../$t" > $t.out 2>&1 || true; tail -60 $t.out | grep -E "Metal vs CPU|ok$|mean|Error|Assert|device" | tail -40; done
REMOTE
