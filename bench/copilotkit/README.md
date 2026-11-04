# CopilotKit comparison runner

A small React app using CopilotKit's own chat (`CopilotChat`, default styles) against an AG-UI agent. It is the
CopilotKit side of the benchmark: the agent streams words, then calls the frontend tool `render_ui` with a UI tree
in its arguments, and the app draws that tree inside the chat while the arguments stream.

## Versions (pinned in package.json)
@copilotkit/react-core, react-ui, runtime 1.84.1 · @ag-ui/client 1.0.2 (the version the runtime itself depends on) ·
React 19.3.1 · Vite 8.3.5 · Node 26.

## Build and run
    npm ci
    npm run build
    AGUI_URL=http://127.0.0.1:8799/ PORT=5180 npm start      # http://127.0.0.1:5180

Env: `AGUI_URL` (required): the AG-UI HTTP endpoint (POST RunAgentInput, SSE back). `PORT` (default 5180).
CopilotKit's runtime telemetry is turned off by default (`COPILOTKIT_TELEMETRY_DISABLED=true` unless you set it).

The scripted agent, from the repo root:

    pixi run python scripts/agui_agent.py --serve --port 8799 --scenario bench

## How the AG-UI agent is wired
- `server.mjs`: one Node `http` server. `/api/copilotkit` is CopilotKit's `copilotRuntimeNodeHttpEndpoint` around
  `new CopilotRuntime({ agents: { bench: new HttpAgent({ url: AGUI_URL }) } })` with `ExperimentalEmptyAdapter`
  (no LLM in the runtime; the agent does everything). Every other path serves `dist/`. The runtime calls the agent
  from the server, so the agent never sees a browser Origin.
- `src/main.jsx`: `<CopilotKit runtimeUrl="/api/copilotkit" agent="bench" useSingleEndpoint>` and `<CopilotChat>`
  filling the window. `useSingleEndpoint` matches the Node endpoint, which is single-route (otherwise the client
  first probes `GET /info` and gets a 405).
- `src/RenderUiTool.jsx`: `useFrontendTool({ name: "render_ui", parameters: [{ name: "ui", type: "object" }],
  render, handler })`. `render({ args, status })` draws `args.ui` (partial while `status` is `inProgress`); the
  handler returns `{ shown: true }`, which CopilotKit sends back to the agent in a follow-up run.
- `src/components.jsx`: plain React for the catalog (VStack, HStack, Grid, Card, Text, KpiView, Meter, ChartView,
  DataGrid, Sparkline, Button, Chip, Divider, Spacer, Alert, Skeleton); unknown components draw nothing, missing
  props are tolerated.

Note: these are CopilotKit's v1 React APIs (`@copilotkit/react-ui` only ships the v1 `CopilotChat`); in 1.84 they
are marked deprecated in favour of `@copilotkit/react-core/v2` but are still the documented way to use react-ui.

## Driving it from a test
Wait for the page's network to go idle (`wait_until="networkidle"` in Playwright) before pressing Enter: CopilotKit
loads the runtime's info and connects the agent (`agent/connect`) after the first paint, and an Enter pressed before
that finishes is ignored (the text stays in the box). Then fill the chat's `textarea`, press Enter and wait for
"end of dashboard". `proof.png` is such a run.
