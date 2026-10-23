#!/usr/bin/env bash
# For each ci/<app>.steps: unzip zips/<app>-*.zip, run the app with its steps, keep its report, a screen picture and crash logs.
set -uo pipefail
mkdir -p out apps
sw_vers > out/macos.txt
system_profiler SPDisplaysDataType > out/displays.txt 2>&1
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
cp -R ~/Desktop/omxcode-report-* out/ 2>/dev/null
mkdir -p out/crashes && cp ~/Library/Logs/DiagnosticReports/*Mojo* out/crashes/ 2>/dev/null
ls -R out | head -50
