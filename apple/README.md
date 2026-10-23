# Mac and iPhone

The same declarative app (for example `examples/hello/app.mojo`) is drawn with AppKit on the Mac and UIKit on the iPhone. Mojo calls Apple's frameworks directly through the Objective-C runtime (`mojoui/hosts/objc.mojo`), so the apps contain no Swift, C or Objective-C. They're linked on Linux with `ld64.lld` against the symbol lists in `apple/sdk/` (see `apple/sdk/README.md`), with Mojo's few runtime functions supplied in Mojo (`mojoui/hosts/mojo_rt.mojo`).

```bash
scripts/build.sh hello mac    # → build/hello/mac/HelloMojo.app and HelloMojo-mac.zip
scripts/build.sh hello ios    # → build/hello/ios/HelloMojo.ipa
```
Use `gallery` (every component) or `todo` (a real todo app) instead of `hello`.

## Mac (Apple Silicon)

**Option 1: copy the app built on Linux** (quickest)
1. `scripts/build.sh hello mac`
2. Copy the zip to the Mac: `scp build/hello/mac/HelloMojo-mac.zip you@your-mac:~/Desktop/`
3. On the Mac: `cd ~/Desktop && unzip HelloMojo-mac.zip && open HelloMojo.app`

**Option 2: build on the Mac**: copy this folder over, install pixi (`curl -fsSL https://pixi.sh/install.sh | sh`), then `scripts/build.sh hello mac && open build/hello/mac/HelloMojo.app`.

**What you should see:** a window titled HelloMojo. Click **Greet** (or press Return) and the title changes to "Hello, Ada! (click 1)", counting up. Cmd+W closes the window and quits; so does Cmd+Q.

**If macOS refuses to open it** ("damaged" or "can't be opened"): that's Gatekeeper, because the app is ad-hoc signed. Copies made with `scp` usually aren't blocked; downloads and AirDrop are. Fix: `xattr -dr com.apple.quarantine HelloMojo.app`, or try to open it once, then System Settings → Privacy & Security → **Open Anyway**.

**If it quits or crashes:** run it from Terminal to see its output, `./HelloMojo.app/Contents/MacOS/HelloMojo`, and check Console.app → Crash Reports. Paste both into the next session.

## Checking a Mac build: maccheck and the Debug menu

The Mac can't be seen from Linux, so the Mac host writes down what it shows (D-290).

1. `scripts/build.sh maccheck mac`, copy `build/maccheck/mac/MaccheckMojo-mac.zip` over (or download `maccheck-mac-arm64.zip` from the release).
2. Open it and press **Run tests**: it walks seven pages (controls, icons and toolbars, layout, canvases, the grid on a Board, changing text, overlays) in about 25 seconds.
3. Zip `~/Desktop/omxcode-report-maccheck/` and send it. Each launch writes its own subfolder, named by its time: `log.txt` (the Mac, every event, every canvas drawn, the problems found), and per change a `NNN-<cause>.png` of the window and a `NNN-<cause>.txt` with every view's kind, text, asked size and frame.

Any Mac app (omxplorer too) has **Debug → Record a report** (⌥⌘R): from then on the same files go to `~/Desktop/omxcode-report-<app>/` after every change. **Take a snapshot** (⌥⌘S) writes one; **Open the report folder** shows it.

## iPhone (free Apple ID, from this Linux machine)

```bash
apple/install_iphone.sh          # or: apple/install_iphone.sh todo
```

The guided script, in order:
1. Builds the `.ipa` if needed (`scripts/build.sh hello ios`).
2. Installs `usbmuxd` (asks first; needs `sudo`) so Linux can talk to the phone over USB.
3. Signs you in to xtool with your Apple ID (`xtool auth login --mode password`, with a 2-factor code).
4. Waits for the iPhone: plug it in, unlock, tap **Trust**.
5. Installs the app with `xtool install`. xtool re-signs it with your Apple ID and prefixes the bundle ID with an ID unique to you.
6. Walks you through the two one-time switches on the phone: **Developer Mode** (Settings → Privacy & Security, then restart) and **trust your Apple ID** (Settings → General → VPN & Device Management).
7. Open the app and tap **Greet**.

**Free Apple ID limits:** the app stops opening after 7 days (run the script again to renew it), and you can have up to 3 self-signed apps at a time.

## Limits and cons
- **Not yet run on real hardware.** Verified here: compiled, linked, signed, symbols and entry point checked. Running on your Mac and iPhone is the real test.
- Apple Silicon only: rects are passed as four floats, which is correct on arm64 and wrong on Intel.
- Marked as built with the 26 SDKs so macOS/iOS 26 give the current Liquid Glass look; unproven without Apple's SDK. If it misbehaves only on 26, change `26.0` back to `14.0`/`17.0` in `scripts/build.sh`.
- `mojoui/hosts/mojo_rt.mojo` is unofficial (read from compiled Mojo 1.1 code) and may need updating with new Mojo releases.
- Each Objective-C call is untyped: a wrong argument type compiles and misbehaves at run time.
