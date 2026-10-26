#!/usr/bin/env bash
# For each ci/<app>.steps: unzip zips/<app>-*.zip, run the app with its steps, keep its report, a screen picture and crash logs.
set -uo pipefail
mkdir -p out apps
sw_vers > out/macos.txt
system_profiler SPDisplaysDataType > out/displays.txt 2>&1
# Scroll bars as a trackpad Mac shows them (overlay): GitHub's Macs have a mouse, so "Automatically" means legacy bars that
# take 17 pt from every scroll view, which AppKit keeps whatever the app asks (the person's choice; 2026-10-25)
defaults write -g AppleShowScrollBars -string WhenScrolling
for steps_file in ci/*.steps; do
    app=$(basename "$steps_file" .steps)
    zip=$(ls zips/"$app"-*.zip | head -1)
    rm -rf "apps/$app" && mkdir -p "apps/$app" && ditto -x -k "$zip" "apps/$app"
    bundle=$(ls -d apps/"$app"/*.app | head -1)
    xattr -cr "$bundle"
    exe="$bundle/Contents/MacOS/$(defaults read "$PWD/$bundle/Contents/Info.plist" CFBundleExecutable)"
    steps=$(grep -v '^#' "$steps_file" | tr -d '\n')
    echo "== $app: $exe"
    start=$(date +%s)
    MOJOUI_TEST="$steps" "$exe" > "out/$app-stdout.txt" 2>&1 &
    pid=$!
    sleep 8 && screencapture -x "out/$app-screen-early.png" 2>/dev/null
    limit=$(( $(head -1 "$steps_file" | sed -n 's/^# limit \([0-9]*\).*/\1/p') ))
    [ "$limit" -gt 0 ] || limit=240
    while kill -0 "$pid" 2>/dev/null; do
        if [ $(( $(date +%s) - start )) -gt "$limit" ]; then
            screencapture -x "out/$app-screen-stuck.png" 2>/dev/null
            echo "TIMEOUT after ${limit}s" >> "out/$app-stdout.txt"
            kill "$pid"
            break
        fi
        sleep 2
    done
    wait "$pid"; echo "exit $?" >> "out/$app-stdout.txt"
    tail -5 "out/$app-stdout.txt"
done
# side.txt: one launch per screen at one size; the last picture of each is out/side/<app>-<screen>.png (scripts/side.py)
mkdir -p out/side
# the console (goal 33 M7) polls a daemon: the recorded replies' server (scripts/console_fixture.py, shipped in the
# sources' tarball with docs/goals/33/fixtures) runs fresh for each of its screens, the clock held at the recording's time
mkdir -p fixture && tar -xzf zips/omxcode-src.tar.gz -C fixture scripts/console_fixture.py docs/goals/33/fixtures 2>/dev/null || echo "no console fixture in the tarball"
while IFS='|' read -r app screen settings steps; do
    case "$app" in ''|'#'*) continue ;; esac
    bundle=$(ls -d apps/"$app"/*.app 2>/dev/null | head -1)
    if [ -z "$bundle" ] && zip=$(ls zips/"$app"-*.zip 2>/dev/null | head -1) && [ -n "$zip" ]; then  # (an app with side lines but no steps file)
        mkdir -p "apps/$app" && ditto -x -k "$zip" "apps/$app" && bundle=$(ls -d apps/"$app"/*.app | head -1) && xattr -cr "$bundle"
    fi
    [ -n "$bundle" ] || continue
    fxpid=""
    if [ "$app" = console ] && [ -f fixture/scripts/console_fixture.py ]; then
        python3 fixture/scripts/console_fixture.py 8765 > "out/side/$app-$screen-fixture.txt" 2>&1 &
        fxpid=$!
        for _ in $(seq 40); do curl -sf -o /dev/null http://127.0.0.1:8765/admin/info && break; sleep 0.25; done
        export MXC_URL=http://127.0.0.1:8765 MXC_ADMIN_KEY=mac-ci
        MOJOUI_NOW=$(python3 -c 'import json; print(json.load(open("fixture/docs/goals/33/fixtures/_manifest.json"))["recorded_at"])')
        export MOJOUI_NOW
    fi
    exe="$bundle/Contents/MacOS/$(defaults read "$PWD/$bundle/Contents/Info.plist" CFBundleExecutable)"
    config="$PWD/out/side/config-$app-$screen" && mkdir -p "$config"
    echo "$settings" | tr ',' '\n' > "$config/settings.txt"
    steps=${steps//\{ci\}/$PWD/ci}  # ({ci}: this folder, where side.txt's files are)
    echo "== side $app $screen"
    OMX_CONFIG="$config" MOJOUI_WINDOW=1440x640 MOJOUI_TEST="$steps" "$exe" < /dev/null > "out/side/$app-$screen.txt" 2>&1 &
    pid=$! start=$(date +%s)
    while kill -0 "$pid" 2>/dev/null; do
        [ $(( $(date +%s) - start )) -gt 120 ] && { echo "TIMEOUT" >> "out/side/$app-$screen.txt"; kill "$pid"; break; }
        sleep 1
    done
    wait "$pid"; echo "exit $?" >> "out/side/$app-$screen.txt"
    if [ -n "$fxpid" ]; then kill "$fxpid" 2>/dev/null; wait "$fxpid" 2>/dev/null; unset MXC_URL MXC_ADMIN_KEY MOJOUI_NOW; fi
    last=$(ls -td ~/Desktop/omxcode-report-"$app"/*/ | head -1)
    shot=$(ls "$last"*.png 2>/dev/null | grep -v -- '-popover\.png$\|-dialog\.png$' | sort | tail -1)
    [ -n "$shot" ] && cp "$shot" "out/side/$app-$screen.png"
    for extra in popover dialog; do [ -f "${shot%.png}-$extra.png" ] && cp "${shot%.png}-$extra.png" "out/side/$app-$screen-$extra.png"; done
    cp "${last}log.txt" "out/side/$app-$screen-log.txt" 2>/dev/null
    dump="${shot%.png}.txt"; [ -f "$dump" ] && cp "$dump" "out/side/$app-$screen-views.txt"
done < ci/side.txt
cp -R ~/Desktop/omxcode-report-* out/ 2>/dev/null
mkdir -p out/crashes && cp ~/Library/Logs/DiagnosticReports/*Mojo* out/crashes/ 2>/dev/null
ls -R out | head -50
