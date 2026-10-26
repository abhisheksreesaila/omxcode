# GOAL 35 (draft, 2026-10-26): Mojo 1.2 and first-class HTTP (flare)

**Why (owner, 2026-10-26):** "we can upgrade to Mojo 1.2… and hence import Ehsan's http libs, and bring in first-class
support to http." After goal 34 (first-class JS); order agreed by the owner. The probe (branch probe-mojo12,
docs/research/mojo12-flare.md) found 1.2 is not a drop-in: the vendored engine is tied to 1.1, one Mac line, and C
functions declared with clashing types; after fixes 40/40 builds and 70/71 tests pass. flare 0.13 works behind
`mojoui.http`'s Transport on worker threads, but HTTPS needs an explicit CA path on 1.2 and it won't link beside mojoui
until the C declarations agree.

## Milestones
| # | Milestone | Proof (`scripts/check`) |
|---|---|---|
| M0 | Its own env | the upgrade happens in a worktree with its own .pixi (never the shared symlink: docs/lessons.md); `mojo --version` is 1.2 there and 1.1 in every other checkout until the merge |
| M1 | The engine on 1.2 | a new engine stable commit built with 1.2 (through omxcore's stable-engine process, as goals 29–32 vendored theirs), vendored with its lineage proved (scripts/engine_lineage.py); its tests pass on Linux; the Metal path on GitHub's Mac runner |
| M2 | One place for C | every `external_call` declaration of a libc/system function lives in one module (`mojoui/libc.mojo`) with the signatures flare and Mojo 1.2's stdlib use; a lint fails on a second declaration anywhere in mojoui/ or examples/ |
| M3 | Everything on 1.2 | every example builds for every platform it lists (linux, web, mac, ios objects: llvm-nm -u, no new KGEN_ symbols); all tests pass; goal 33's and goal 34's checks pass |
| M4 | flare behind mojoui.http | `-D MOJOUI_FLARE` selects a FlareTransport: tests/test_http.mojo passes on it, plus HTTPS to a local TLS test server (a self-signed CA passed explicitly) and to a public site; HTTP/2 negotiated; the socket transport stays the default where flare isn't available (iPhone, Android) |
| M5 | Live channels | websocket and SSE as effects (`mojoui.http` streams: messages arrive as Events, never blocking a frame), proved against a local echo server on GTK and the web |
| M6 | Shipping | apps that use flare bundle OpenSSL and flare's small libraries (Linux package, Mac zip through mac-ci); the Mac runner runs an HTTPS request |

## Out of bounds
A native Mojo web host (goal 36 measures FastHTML first); iPhone and Android TLS; changing omxcore's code beyond what
1.2 needs; pushing anything but mac-test and the engine's own release flow.

## Risks
flare changes fast (5 releases in 3 months); a C-declaration clash can return with each Mojo bump (M2's lint catches
it); flare installs from conda while Mojo comes from PyPI here.
