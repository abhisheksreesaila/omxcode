# GOAL 35: AG-UI, agents that build the screen

**End goal (owner, 2026-10-27):** "let's plan to wrap up 34b and AG-UI tonight; I want to submit to a tech fund."
Earlier: "we provide an agent-native framework… we give agents metadata for rendering UI… by supporting AG-UI, by
spitting out metadata, not the actual interface, and having the runtime do it… people can put their own harness."
AG-UI (docs.ag-ui.com) is an open event protocol between an agent backend and a UI: a run streams text, tool calls
and shared state as events over HTTP (SSE).

## Milestones
| # | Milestone | Proof (`scripts/check`) |
|---|---|---|
| M0 | Streaming HTTP | `mojoui.http` streams: a request may ask for a stream; each SSE event (or chunk) arrives as its own `Event` in `update()` while frames keep drawing, then an end Event; through the Transport seam (sockets today); tests against a Python SSE server: 200 events in order, a slow trickle, a dropped connection mid-stream, a timeout, cancel by the app |
| M1 | The AG-UI client | `mojoui/agui.mojo`: runs an agent (POST RunAgentInput: thread, run, messages, state, tools), reads the AG-UI event stream (RUN_STARTED/FINISHED/ERROR, TEXT_MESSAGE_START/CONTENT/END, TOOL_CALL_START/ARGS/END/RESULT, STATE_SNAPSHOT, STATE_DELTA as JSON Patch, MESSAGES_SNAPSHOT, STEP_*, CUSTOM), keeps the conversation and the shared state, applies JSON Patch exactly (RFC 6902 tests), and lets the app answer frontend tool calls; its own tests against recorded streams from the official AG-UI Python SDK |
| M2 | Generative UI | the agent sends UI as data, never code: a frontend tool (e.g. `render_ui`) whose arguments are a view description built only from catalogued omxcode components (a JSON schema generated from the component catalog: Text, Card, Table, Chart/Sparkline, Button, TextField, Toggle, Segmented, Meter, Paragraph…); the app validates it against the schema (unknown component, bad prop, too deep or too big → refused with a message to the agent) and renders it natively; a button in agent-built UI reports back to the agent as a tool result; shared state edited in the UI reaches the agent as state |
| M3 | A chat app on the web and Linux | `examples/agentchat`: a chat panel; the agent streams its words, builds a chart or a form in the conversation, the user edits it and the agent sees the change; a scripted AG-UI agent (Python, official SDK, deterministic) makes the checks repeatable; a live agent backed by Claude runs when an API key is set by env var name (never stored or logged); on GTK and the web; screenshots |
| M4 | Nothing regressed (minimal) | goal 34b's M0 and goal 34's M2 and goal 33's M1 pass |

## Out of bounds
Running untrusted code from the agent; storing keys; the Mac (later, through the same seam); AG-UI server hosting
beyond localhost; pushing.

## Assumptions
- Streaming goes through our own HTTP/1.1 socket transport (plain HTTP to a local agent); flare stays goal 37.
- The scripted agent drives every check; the live Claude agent is a demo path (`claude-api` model ids, latest).
- Each milestone's proof is written before its work, from this table's words, never weaker.

## Done means
`scripts/check` PASS for M0–M4; the reviewer passes it; a short report with the agent building UI in the chat app.
