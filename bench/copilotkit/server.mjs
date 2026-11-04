// One Node server: CopilotRuntime at /api/copilotkit (proxying to the AG-UI agent at AGUI_URL), and the built frontend.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

// A benchmark runner should not phone home: CopilotKit's runtime telemetry is off unless asked for.
process.env.COPILOTKIT_TELEMETRY_DISABLED ??= "true";
const { CopilotRuntime, ExperimentalEmptyAdapter, copilotRuntimeNodeHttpEndpoint } = await import("@copilotkit/runtime");
const { HttpAgent } = await import("@ag-ui/client");

const PORT = Number(process.env.PORT || 5180);
const AGUI_URL = process.env.AGUI_URL;
if (!AGUI_URL) {
  console.error("AGUI_URL is required (the AG-UI agent's HTTP endpoint)");
  process.exit(1);
}

const runtime = new CopilotRuntime({ agents: { bench: new HttpAgent({ url: AGUI_URL }) } });
const copilot = copilotRuntimeNodeHttpEndpoint({
  endpoint: "/api/copilotkit",
  runtime,
  serviceAdapter: new ExperimentalEmptyAdapter(),
});

const DIST = join(fileURLToPath(new URL(".", import.meta.url)), "dist");
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".json": "application/json" };

async function serveStatic(req, res) {
  const path = normalize(decodeURIComponent(new URL(req.url, "http://x").pathname)).replace(/^(\.\.[/\\])+/, "");
  let file = join(DIST, path);
  if (!file.startsWith(DIST)) return res.writeHead(403).end();
  let body;
  try {
    body = await readFile(file);
  } catch {
    file = join(DIST, "index.html");
    body = await readFile(file);
  }
  res.writeHead(200, { "content-type": TYPES[extname(file)] || "application/octet-stream" }).end(body);
}

createServer((req, res) => {
  if (req.url.startsWith("/api/copilotkit")) return copilot(req, res);
  serveStatic(req, res).catch((e) => res.writeHead(500).end(String(e)));
}).listen(PORT, "127.0.0.1", () => console.log(`http://127.0.0.1:${PORT}  (agent "bench" -> ${AGUI_URL})`));
