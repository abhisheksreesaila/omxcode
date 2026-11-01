# X: omxcode, the framework thread (Tuesday Nov 3)

Post 1/ first, then reply to it with each next post. Attach the media named under each post. Every post is under 280
characters (`pixi run python docs/launch/kit/x/check_lengths.py`). Copy only the text between the lines.

---
**1/** · attach `[YouTube: omxcode part 1]` (or `[shot: code-file]`)

The framework under omxplorer: omxcode.

An app is one Mojo struct with update() and view(). The same file opens natively on Linux (GTK), the web and the Mac (AppKit, checked on GitHub's virtual Macs), and the GPU kernel sits in the same file. 🧵

---
**2/** · attach `[shot: mac-linux]`

No web view on the desktop. A button is a GtkButton, an NSButton (on GitHub's virtual Macs), a real Android widget on the emulator.

Each host diffs the view tree and patches only what changed. Mojo calls C and Objective-C directly: no binding generator.

---
**3/** · attach `[clip: never-freeze]`

The window never freezes, by one rule: update() and view() only decide.

Queries, video and documents run on worker threads and come back as events. No locks in app code. MOJOUI_BUDGET_MS prints a SLOW: line for anything over budget.

---
**4/** · attach `[shot: mcp-tools]`

Every omxcode app is an MCP server, with no per-app code.

A button's tag is the tool's name. Calling it is tapping it. A disabled button isn't a tool. Each call answers in words: "Did greet. Now: Hello, Ada! (click 1)"

---
**5/** · no media

Public alpha, MIT. Where Mojo pushed back (FFI, a SIMD compiler crash, phone targets) is in the forum post.

github.com/abhisheksreesaila/omxcode

---

*Sources: hosts README.md, docs/components.md; diff docs/architecture.md; threads docs/ui-threads.md (S5); MCP
docs/agent.md (S11), the hello transcript a real run of scripts/agent_client.py (2026-11-01); S15. After omxlabs.tech is
live you may add it to 5/.*
