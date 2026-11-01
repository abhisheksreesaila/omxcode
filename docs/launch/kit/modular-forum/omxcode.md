# Modular forum: omxcode, the framework post (Tuesday Nov 3)

**Where:** forum.modular.com → **Community Showcase**. Tags if offered: `ui`, `gpu`, `showcase`.

**Attach:** the YouTube link for `[YouTube: omxcode part 1]` (talks/omxcode/part1) under the first paragraph, then
`[shot: code-file]` after the code block and `[shot: mac-linux]` at the end.

## Title (pick one)

1. omxcode: writing native apps in Mojo, how it works under the hood
2. One Mojo struct → GTK, the web, AppKit and MCP tools: omxcode's design
3. A Mojo UI framework where the window never freezes and agents can drive every app

*(1 for developers who saw Sunday's post; 3 if you're posting it on its own.)*

## Body (copy from here)

On Sunday I showed omxplorer, a robot-data app ([Sunday's post](LINK-TO-SUNDAY-POST)). Today is the framework under it, **omxcode**, for anyone who wants to write apps in Mojo themselves.

[YouTube: omxcode part 1]

**An app is one struct.** State, `update()` and `view()`, the Elm/SwiftUI shape (examples/hello/app.mojo, trimmed):

```mojo
comptime GREET = 1   # a message is just a number

struct Main(App):
    var name: String
    var clicks: Int

    def update(mut self, event: Event):
        if event.message == GREET:
            self.clicks += 1

    def view(self) -> View:
        var greeting = "Tap Greet" if self.clicks == 0 else "Hello, " + self.name + "! (click " + String(self.clicks) + ")"
        return VStack(
            Text(greeting, style=TITLE),
            Button("Greet", on_tap=GREET, style=PROMINENT),
            spacing=20,
        )
```

**Native hosts, no web view on the desktop.** The view tree is drawn by GTK 4 on Linux, by FastHTML + HTMX on the web, by AppKit on the Mac (checked on GitHub's virtual Macs), and by real Android views over JNI on the emulator; the iPhone build compiles and signs but hasn't run on a phone. `scripts/build.sh hello all` cross-builds the Mac and iPhone apps on Linux. Each host diffs the old tree against the new one and patches only what changed; widgets hold a message number, never a closure. Mojo calls C and Objective-C directly, so there's no binding generator anywhere.

**The GPU in the same file.** A plain Mojo function, `mandelbrot(x, y, w, h, p) -> UInt32`, becomes a kernel through `gpu.render[mandelbrot](...)`; mojoui launches it in 16 × 16 blocks, and the same function runs on the CPU to check the pixels. The Data Lens draws 20M points in 1.5 ms a frame on an RTX 3090 (130 ms on the CPU, same pixels).

**The window never freezes, by one rule.** `update()` and `view()` run on the UI thread and only decide. Network calls, timers, queries, imports, video decoding and documents run on worker threads and come back as ordinary events, so app state is never touched off the UI thread and there are no locks in app code. A finished job wakes GTK's main loop through a pipe (0.02–0.05 ms median on Linux). A watchdog, `MOJOUI_BUDGET_MS=N`, prints `SLOW: update msg=…` for anything over budget. On GitHub's virtual Macs, giving jobs their own threads took a 1.5 s job's worst frame gap from 1,516–1,527 ms to 71–83 ms.

**Every app is an MCP server.** One more host turns the same view tree into tools: a button's tag is the tool's name, its tooltip the description, calling it is tapping it. A disabled button is no tool, and a dialog's buttons exist only while it's open. Each call answers with what changed, in words:

```text
→ greet
← Did greet.
  Now: Hello, Ada! (click 1)
```

**Where Mojo pushed back, in case it saves someone a day:**
- FFI is scalars and `(pointer, length)` strings; exports (`@export` + `abi("C")`) can't raise. State that C holds is allocated in Mojo and passed as an address.
- A `SIMD` vector indexed at run time as scratch space (`stack[sp] = v`) crashed the compiler with no message; `stack_allocation[n, T]()` works.
- Phone targets need two runtime functions (`KGEN_CompilerRT_AlignedAlloc` / `AlignedFree`) that I stand in for with a small, labelled C shim. An official answer here would unblock a lot.
- Linking a Mojo shared library needs `-Xlinker -rpath -Xlinker '$ORIGIN'`.

**Honest edges:** Mojo 1.1 has no Windows release; Android runs 19 of the 174 components in the matrix so far; the iPhone only builds; the GPU path is NVIDIA first (Apple's GPU through Metal is checked on CI Macs only). In a five-stack benchmark, native Rust beats omxcode at 1M particles, cold start and memory; at 20M, JS + WebGPU is 3.01 ms and omxcode 3.13 ms, in one file. All of it is in `docs/benchmarks.md`.

Public alpha, MIT:
https://github.com/abhisheksreesaila/omxcode

```bash
git clone https://github.com/abhisheksreesaila/omxcode && cd omxcode && pixi install
scripts/build.sh hello all     # GTK, web, Mac and iPhone builds
scripts/agent.sh hello         # prints the claude mcp add line
```

I'd really like to hear how you'd have done the FFI layer or the job threads differently in Mojo.

[shot: mac-linux]

---

*Sources (not for posting): hello code examples/hello/app.mojo; hosts README.md "Where it stands", docs/components.md
("Totals": Android ✅ 19 of 174); diff docs/architecture.md; GPU examples/gpu/app.mojo, mojoui/gpu.mojo, README.md
"Measured" (S4); threads docs/ui-threads.md, D-792 (S5, S8); MCP docs/agent.md (S11), transcript a real run of
scripts/agent_client.py build/hello/web (2026-11-01); Mojo limits CLAUDE.md "Mojo rules that bite", spike/kgen_shim.c
(S15); benchmark docs/benchmarks.md. Replace LINK-TO-SUNDAY-POST before posting.*
