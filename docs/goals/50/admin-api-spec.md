# omxconsole admin + /v1 API: how each reply is computed

Source: `~/Projects/mxstudio/mxconsole/` at HEAD 67af023 (read-only). Fixtures: `docs/goals/33/fixtures/` (recorded at mxstudio 798ef8c, before LiteLLM was removed, F-063). Every error status and message below was checked against the running Python app (Starlette TestClient, loopback client, temp `MXC_HOME`).

## 0. Conventions

| Item | Rule |
|---|---|
| Daemon | `127.0.0.1:{PORT}`, PORT = env `MXC_PORT` (falls back to `HOTFIRE_PORT`, then `MST_PORT`), default **11435** |
| Env prefixes | Every setting `X` reads `MXC_X`, then `HOTFIRE_X`, then `MST_X`. Used: `PORT`, `EXPOSE_PORT` (8443), `HOME` (default `~/.mxc`), `MAX_CMD` (default `max`, shell-split), `GRAPH_CAPTURE`, `GPU_MEMORY_FRACTION` |
| Home | `H = ~/.mxc`. Store `H/mst.db` (WAL, busy_timeout 10 s). Model logs `H/logs/<name>.log`, daemon log `H/logs/daemon.log`, run files `H/run/`, Caddy `H/expose/`, notebooks `H/notebooks/<name>.ipynb`, ports `H/ports/<id>/port.log`, MAX catalog cache `H/max_catalog.json` |
| JSON | Starlette `JSONResponse`: compact (`,` `:` with no spaces), UTF-8 emitted raw (`ensure_ascii=False`, so `·` appears as is). Floats use Python `repr`: shortest round-trip form, and a whole-number float keeps `.0` (`24.0`, `1000000.0`). Ints stay ints. `None` → `null` |
| `round(x, n)` | Python rounding: correctly rounded from the binary double, ties go to even |
| Times | `ts`, `*_at` = Unix seconds as a float (`time.time()`). "Today" = since local midnight, `mktime(localtime()[:3]+(0,0,0,0,0,-1))` |
| Error JSON (OpenAI shape) | `{"error":{"message":str,"type":str,"param":null,"code":str}}`. `type` defaults to `"invalid_request_error"`; `"server_error"` / `"authentication_error"` where noted |
| Unknown route | Any path with no route (for example `/admin/litellm/log` now): **404**, body `404 Not Found`, no content-type header |

## 1. Admin auth rule (every `/admin/*` route)

Allowed only when **all** of these hold:
1. The client IP (TCP peer) is in `{"127.0.0.1","::1","localhost"}`.
2. Neither an `X-Forwarded-For` nor a `Forwarded` header is present (Caddy sets them for LAN clients).
3. The `Host` header, after cutting the last `:port` (`rsplit(":",1)[0]`) and stripping `[]`, is in the same set (guards against DNS rebinding). A missing Host gives `""`, which is refused.
4. `X-Mst-Admin` is exactly `1` (`true` or `yes` are refused).
5. `Origin` is absent, or its host (after `://`, minus `:port`, minus `[]`) is in the set.

Refused: **403**, body `admin is only served to this machine` (plain text, **no content-type header**). Each refusal increments the in-memory counter `admin_refused` (see /admin/gateway). There is no 401 on admin routes.
The console HTML, `/docs` and `/openapi.json` use rules 1 to 3 only (`loopback_only`), and their refusals are not counted.

## 2. Supervisor state (in memory; the Mojo daemon must keep the same)

One child record per running model: `{proc, port, last_used (monotonic), ready, crashed, in_flight, started_at, gpu}`.
`status()` returns, for every name in (models table ∪ children), **sorted by name**:

| key | type | value |
|---|---|---|
| name | str | |
| state | str | `cold` (no child), `starting` (child, not ready), `ready`, `crashed` (child process has exited; sticky) |
| port | int\|null | child port, else null |
| pid | int\|null | child pid |
| idle_seconds | float\|null | `now_mono - last_used`, only when ready and not crashed |
| starting_seconds | float\|null | `now_mono - started_at`, only when starting |
| pinned | bool | from models |
| in_flight | int | open proxied requests (0 when no child) |

### 2.1 Starting a model (`ensure_running(name)`)
- Not in `models` → UnknownModel (404 at the callers).
- Child ready and alive → set `last_used = now` and return `http://127.0.0.1:{port}/v1`.
- Otherwise start it. Concurrent callers share one start. Up to **3 attempts**, each on a fresh port:
  - Port: bind `127.0.0.1:0`, read the port the OS picked, close the socket.
  - GPU: from nvidia-smi (§3.4). Prefer GPUs with free ≥ 4096 MB (else all); pick the minimum of (number of our children on that GPU, −free MB). No GPUs → none.
  - **Command** (argv, no shell):
    ```
    {MAX_CMD...} serve --port {port} --served-model-name {name}
      [--no-device-graph-capture]              # omitted only when GRAPH_CAPTURE == "1"
      [--devices gpu:{i}]                      # only when a GPU was picked and it isn't "unified" (Mac)
      --device-memory-utilization {F}
      [--custom-architectures {custom_arch_path}]   # when models.custom_arch_path is set
      --model-path {weights_path}                   # when weights_path is an existing directory; else:
      --model-path {repo_id} [--huggingface-model-revision {revision}]   # revision when non-empty
    ```
  - `F` = env `GPU_MEMORY_FRACTION` if set, else `memory_fraction(wb, total_mb)`: `wb` = sum of sizes of the **top-level** `*.safetensors|*.bin|*.gguf` in weights_path (symlinks followed; 0 → none); `total_mb` = the picked GPU's total. When either is missing → `"0.35"`. Otherwise `need = (wb*1.1 + 4 GiB) / (total_mb * 2^20)`; `need <= 0.35` → `"0.35"`, else `str(round(min(0.9, need), 2))` (for example `"0.47"`, `"0.9"`).
  - Env: the daemon's whole environment plus `MAX_SERVE_HOST=127.0.0.1`. stdout and stderr are appended to `H/logs/<name>.log`; stdin is /dev/null; new session (own process group); Linux `prctl(PR_SET_PDEATHSIG, SIGTERM)`.
  - Pid file `H/run/<name>.<pid>.pid` containing `"<pid> <pid>"`.
  - Health: every 0.1 s, `GET http://127.0.0.1:{port}/health` (2 s timeout). On 200, `GET /v1/models` must list `name` in `data[].id`; a 200 without it means a port clash, so the daemon retries on a new port.
  - Child exited: if the log tail contains `in use` (any case) → port clash, retry. Otherwise fail with `max serve for '{name}' exited with code {N}:\n{tail}`. `tail` = the last 2000 bytes of the model log written since this start, stripped.
  - Deadline 600 s → `max serve for '{name}' was not healthy after 600s:\n{tail}`. Three clashes → `could not find a free port for '{name}': ...`. Spawn OSError → `could not run {max_cmd}: {e}`.
- On success: `ready=true, last_used=now`.

### 2.2 Life cycle
- Each proxied request: `in_flight += 1` and `last_used = now` on entry; `in_flight -= 1` and `last_used = now` on exit (when the body stream ends).
- Reaper every **15 s**: (a) `DELETE FROM requests WHERE ts < now-7*86400`; (b) for each child that is ready, alive and has `in_flight == 0`, where the model is not pinned and `now - last_used > keep_alive` (models.keep_alive, seconds, default 300): stop it.
- Stop: SIGTERM the process group, wait up to 10 s, SIGKILL the group, reap, delete the pid file. A start in progress is cancelled first.
- Daemon start: flock `H/run/daemon.lock` (contents `"<pid> <starttime>"`; a second daemon exits). Sweep orphans: for each `H/run/*.pid` whose process is alive, has `serve` in its cmdline and has the recorded pgid → SIGKILL that group; delete the file.

## 3. Shared readers

### 3.1 `expose.status()` / LAN endpoint (Caddy is optional)
- Caddy counts as running iff `H/expose/caddy.pid` holds `"<pid> <start>"` and field 22 of `/proc/<pid>/stat` (index 19 after the last `)`) equals `<start>`, and the process isn't a zombie.
- `status()` = `{"caddy": bool}`. The fixture has `{"caddy":false,"litellm":false}`.
- `lan_endpoint` = `"https://{trim(H/expose/host)}:{EXPOSE_PORT}/v1"` when Caddy runs and the file is readable, else `null`.
- `default_host` = `"{gethostname()}.local"`. `ca_path` = `${XDG_DATA_HOME:-~/.local/share}/caddy/pki/authorities/local/root.crt`.
- With Caddy off: `exposed=false`, `lan_endpoint=null`, `tls.on=false`. Nothing else changes.

### 3.2 /proc stats for a pid
`/proc/<pid>/stat`: split after the last `)`. State `Z` or unreadable → no stats. `rss_mb = round(VmRSS_kB/1024, 1)` (from `/proc/<pid>/status`). `uptime_seconds = round(max(0, /proc/uptime[0] - starttime_ticks/CLK_TCK))` as an int.

### 3.3 Counters (in memory, reset when the daemon restarts and at local midnight)
`since` = `time.time()` when the daemon started (float). `admin_refused`: +1 per refused admin call. `unknown_route`: +1 per hit on `/v1/{anything else}`, counted before auth.

### 3.4 nvidia-smi
- `metrics.gpus()`: `nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits` (5 s timeout) → per line `{"index":int,"name":str,"used_mb":int,"total_mb":int,"util":int}`. Lines without exactly 5 fields or with non-integers are skipped. Missing binary or an error → `[]`. (macOS: one entry `{"index":0,"name":cpu brand,"used_mb","total_mb","util":null,"unified":true}`.)
- `gpu_processes()`: `nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits` → `{pid: MB}` summed per pid; `[N/A]` lines skipped.

### 3.5 `weights_size(weights_path)` → `size_bytes`
null if the path is empty or missing. A file → its size. A directory → recursive sum of every regular file (symlinks followed; includes config and tokenizer files, not only weights). More than 2000 files → null. A total of 0 → null. Cached per (path, mtime_ns).

## 4. GET replies

### GET /admin/info
| key | type | how |
|---|---|---|
| host | str | `gethostname()` |
| endpoint | str | `"http://{Host header or '127.0.0.1'}/v1"` (the Host value includes its port) |
| docs | str | same base + `/docs` |
| lan_endpoint | str\|null | §3.1 |
| max_version | str\|null | the first file (sorted) `{sys.prefix}/conda-meta/max-[0-9]*.json` whose JSON has `name=="max"` → its `version` (for example `26.7.0.dev2026100905`). For Mojo: the same glob in the pixi env that runs `max` |
| uptime_seconds | int | `round(monotonic_now - app_created)` |
| active_keys | int | `SELECT COUNT(*) FROM keys WHERE revoked_at IS NULL AND app NOT LIKE '\_%' ESCAPE '\'` |
| blocked_today | int | `SELECT COUNT(*) FROM requests WHERE status=401 AND ts >= local_midnight` |
The fixture matches.

### GET /admin/system
`{"crew":[...],"listeners":[...],"home":str,"logs":[...],"gpu":obj|null,"gpus":[...]}`
- **crew**, in this order:
  1. `{"id":"daemon","kind":"daemon","name":"omxconsole daemon","state":"running"|"stopped","pid":getpid(),"port":PORT,"rss_mb","uptime_seconds"}` (§3.2; when there are no stats, pid, rss_mb and uptime_seconds are null)
  2. `{"id":"caddy","kind":"caddy","name":"Caddy",...,"port":EXPOSE_PORT}`, pid from `H/expose/caddy.pid` when valid (§3.1), else `state:"stopped"` with nulls
  3. One per supervisor row that has a pid (states starting, ready or crashed), in status order: `{"id":"model:<name>","kind":"model","name","state":<supervisor state>,"pid","port","rss_mb","uptime_seconds","vram_gb"}`
- `vram_gb` (models only): for each `(pid, MB)` from gpu_processes, walk up the parents (`/proc/<p>/stat` field 4, at most 16 hops); if the model's pid is reached, add the MB. Result `round(total/1024, 2)`, or null when nothing matched. gpu_processes is only queried when `gpu` is non-null; otherwise every vram_gb is null.
- **listeners** (fixed text):
  | name | kind | host | port | exposed | state | talks_to |
  |---|---|---|---|---|---|---|
  | omxconsole daemon | daemon | 127.0.0.1 | PORT | false | `listening` if the daemon crew row is running, else `off` | `the mxc CLI, this console, your apps on this machine, and Caddy (key check, then every LAN request)` |
  | Caddy | caddy | 0.0.0.0 | EXPOSE_PORT | true | same, from the caddy row | `LAN clients over HTTPS, each with an app key` |
  | Caddy admin | caddy | 127.0.0.1 | 2099 | false | same, from the caddy row | `Caddy itself (its config API)` |
  | `max serve · <name>` per model crew row | model | 127.0.0.1 | child port | false | `listening` if state ∈ {ready, running}, else the state | `the daemon only` |
- **home**: absolute path of H.
- **logs**: `{"id":"daemon","label":"Daemon"}` if `H/logs/daemon.log` exists, then `{"id":"caddy","label":"Caddy"}` if `H/expose/caddy.log` exists, then `{"id":"model:<name>","label":<name>}` for every model ordered by name (whether or not a log exists).
- **gpus**: per nvidia GPU `{"index","name","vram_total_gb":round(total_mb/1024,1),"vram_used_gb":round(used_mb/1024,1)}`.
- **gpu**: null if there are no GPUs. Otherwise `{"name","count","vram_total_gb","vram_used_gb"}`: the sums are taken over the **already rounded** per-GPU values, then `round(...,1)`. Name: distinct names joined with `", "` when there is more than one name; otherwise the name, plus `" x{n}"` when n > 1.
- Differences from the fixture: the fixture crew also has `{"id":"litellm","kind":"litellm","name":"LiteLLM","port":4000,...}`, and its listeners have a `LiteLLM` row (127.0.0.1:4000, "Caddy only (its UI opens from this machine)"). The daemon's talks_to was `"... your apps on this machine, LiteLLM and Caddy's key check"`. All of that is **removed now**. The fixture logs have no daemon entry because the recording's home had no daemon.log.

### GET /admin/models
Array, `SELECT * FROM models ORDER BY name`; each:
| key | type | how |
|---|---|---|
| name, repo_id, revision, source, architecture | str | columns. `source` ∈ `max-catalog`, `hf-supported` (pull) or `port` (automatic port). The fixture's `"huggingface"` is seeded test data |
| pinned | bool | `pinned != 0` |
| keep_alive | int | column (seconds) |
| kind | str | column: chat, coder, vision, embeddings or image |
| size_bytes | int\|null | §3.5 on weights_path |
| labels | [str] | `SELECT label FROM model_labels WHERE model=? ORDER BY label` |
| state, port, idle_seconds, starting_seconds | | supervisor row (§2); defaults `"cold"`, null, null, null |
| in_flight | int | supervisor row, default 0 |
The fixture matches the current key set exactly.

### GET /admin/labels
`[{"name":str,"position":int,"count":int}]` from
`SELECT l.name, l.position, COUNT(x.name) n FROM labels l LEFT JOIN model_labels m ON m.label=l.name LEFT JOIN models x ON x.name=m.model GROUP BY l.name ORDER BY l.position`. The count includes only links to models that still exist. Positions are never compacted after a delete (gaps are normal).

### GET /admin/keys
`SELECT * FROM keys ORDER BY app`, skipping apps that start with `_` (internal: `_bench`, `_notebook`, legacy `_litellm`). Each row: `{"app","prefix","created_at":float,"last_used_at":float|null,"revoked_at":float|null,"status":"revoked" if revoked_at else "active"}`. The fixture matches.

### GET /admin/gateway
```
{"counters_since": counters.since (float),
 "tls": {"on": lan_endpoint != null, "endpoint": lan_endpoint},
 "keys": {"active": n(revoked_at IS NULL), "revoked": n(revoked_at NOT NULL)},   # '_' apps excluded
 "unauthorized_today": COUNT(requests status=401, ts>=midnight),
 "unknown_routes_today": counters.unknown_route,
 "admin_refused_today": counters.admin_refused,
 "enforced_by_caddy": ["dot_segments","secrets"]}   # constant
```
The fixture matches.

### GET /admin/network
| key | how |
|---|---|
| host | gethostname() |
| expose | `{"caddy":bool}` (§3.1) |
| exposed | `expose.caddy` |
| lan_endpoint, default_host, ca_path | §3.1 |
| ca_exists | ca_path exists |
| ports | `{"daemon":PORT,"caddy":EXPOSE_PORT}` |
| models | per model (by name): `{"name","state","port","recent"}`. state and port from the supervisor (`cold`/null by default); `recent` = per_model[name] or 0 |
| apps | `SELECT app, COUNT(*) AS requests, MAX(ts) AS last_ts FROM requests WHERE ts >= now-86400 AND app IS NOT NULL AND app NOT LIKE '\_%' ESCAPE '\' AND app != 'console' GROUP BY app ORDER BY last_ts DESC LIMIT 8` → `[{"app","requests":int,"last_ts":float}]` |
| recent_requests | sum over **all** groups of `SELECT model, COUNT(*) n FROM requests WHERE ts >= now-60 GROUP BY model`, **including the NULL-model group** (401s, 400s) |
`per_model` is that same 60 s query. Differences from the fixture: it has `expose.litellm` and `ports.litellm: 4000`; both are gone now.

### GET /admin/metrics?range=5m
`range` ∈ {5m:300, 1h:3600, 24h:86400, 7d:604800} (default `5m`). Anything else → 400 `range must be one of 5m, 1h, 24h, 7d`, code `invalid_range`.
Rows = `SELECT * FROM requests WHERE ts >= now - window`.
`stats(rows)`: ok = rows with `status < 400`.
- `requests` = len(rows); `errors` = len − len(ok)
- `ttft_p50_ms`, `ttft_p95_ms` = pct(non-null ttft_ms of ok rows, 0.5 / 0.95)
- `decode_tps_p50` = pct(decode_tps of ok rows, 0.5), where decode_tps = `(completion_tokens-1) / ((duration_ms - ttft_ms)/1000)`. It is null when completion_tokens is null or < 2, when ttft is null, or when the denominator is ≤ 0.
- `pct(v,p)`: null if empty. Sort; `k=(n-1)*p`; `lo=floor(k)`, `hi=min(lo+1,n-1)`; `round(v[lo]+(v[hi]-v[lo])*(k-lo), 1)`.

Reply: `{...stats(rows), "window_seconds":int, "per_minute":round(n/(window/60),2), "error_rate": round(errors/n,3) if n else 0.0, "by_model":{model: stats(rows of model)} for non-null models sorted by name, "gpus": metrics.gpus() (§3.4, raw mb and util)}`. Key order: requests, errors, ttft_p50_ms, ttft_p95_ms, decode_tps_p50, window_seconds, per_minute, error_rate, by_model, gpus. The fixture matches. Totals include NULL-model rows (101 by_model vs 103 total in the fixture).

### GET /admin/series?range=5m
Default range `1h`; the same 400 as metrics. `(span, step)`: 5m (300, 10), 1h (3600, 60), 24h (86400, 1800), 7d (604800, 10800).
`count = span/step`; `first = (floor(now)//step - count + 1) * step` (buckets sit on the clock; the last one holds now).
Rows = `SELECT * FROM requests WHERE ts >= first AND model IS NOT NULL`; bucket `i = int(ts - first) // step`, kept when `0 <= i < count`.
```
{"range":str,"bucket_seconds":step,"start":first,"end":first+count*step,
 "buckets":[first+i*step for i<count],
 "models":{name:[{"t","requests","errors","ok","ttft_p50_ms","decode_tps_p50"} x count]}}
```
Only models with at least one row in range appear, sorted by name; empty buckets are filled with zeros and nulls. The per-bucket stats are §metrics `stats`. The fixture matches.

### GET /admin/requests?limit=40
`limit` default 50, clamped to 1..500; a non-integer → 50. Optional `model=` adds `WHERE model = ?`.
`SELECT * FROM requests [WHERE model=?] ORDER BY ts DESC, id DESC LIMIT ?` → every column as is (`id,ts,app,model,route,status,prompt_tokens,completion_tokens,ttft_ms,duration_ms`), with `estimated` as a bool. The fixture matches.

### GET /admin/bench
`{"running":bool,"progress":obj|null,"latest":run|null}`
- `progress` (only while a run is live, in memory): `{"id","runs","started_at","models":[{"name","state":queued|loading|warming|running|done|failed,"done":int,"error":str|null}]}`. Once a model finishes, its entry also gets `decode_tps` and `load_seconds` (a model that fails gets `load_seconds` only).
- `latest` = run_dict of `SELECT * FROM bench_runs WHERE status IN ('done','failed') ORDER BY started_at DESC, id DESC LIMIT 1`.
- **run_dict(row)**: every bench_runs column (`id,started_at,finished_at,status,runs,max_tokens,prompt_tokens`), plus `models` = JSON-decoded list, plus `results` = `SELECT * FROM bench_results WHERE run_id=?` with `estimated`, `prompt_estimated` and `completion_estimated` as bools. Sorted by (decode_tps null last, decode_tps desc, model asc); `place` = 1, 2, ... added **only** to results with a non-null decode_tps (the key is absent otherwise).
- Daemon start: `UPDATE bench_runs SET status='interrupted', finished_at=now WHERE status='running'` and revoke the `_bench` key.
The fixture matches.

### GET /admin/bench/history?limit=10
`limit` default 20, clamped to 1..100, a non-integer → 20. `SELECT * FROM bench_runs ORDER BY started_at DESC, id DESC LIMIT ?` → `[run_dict]`, all statuses (running and interrupted included).

### GET /admin/pulls
`{"pulls":[view], "curated":CURATED (object, §7), "fake_hub":true (only in test mode, MXC_FAKE_HUB)}`
Rows: `SELECT * FROM pulls ORDER BY id DESC LIMIT 20`; a live job uses its in-memory view instead. A view rebuilt from a row:
| key | how |
|---|---|
| id, ref, name, repo_id, status, step, message, hint, error_kind, started_at, finished_at, model | columns. status ∈ running, done, failed, cancelled, unsupported. step ∈ resolve, architecture, download, verify, register |
| files | `json(files)` → `[{"name","size":int\|null,"done":int,"state"}]`, state = `done` if size and done ≥ size, `now` if done > 0, else `next` |
| total_bytes / done_bytes | sums over files (size null counts as 0); not the columns |
| percent | total > 0: `100.0` if status=done else `round(done*100/total,1)`; total = 0: `100.0` if done else null |
| speed | int; always 0 for a row (only a live download has speed: bytes over the last 4 s) |
| eta_seconds | `round((total-done)/speed)` when speed > 0 and total > done, else null |
| steps | for each (id,label) in [(resolve,Resolve),(architecture,Architecture),(download,Download),(verify,Verify),(register,Register)]: state = `done` if status=done or the step is before the current one; at the current step: `now` if running, `cancelled` if cancelled, else `failed`; after it: `next`. `detail` = `json(details)[id]` or `""` |
At startup every `running` row becomes `status='failed', error_kind='interrupted', message='interrupted: the daemon stopped during this pull. Pull it again to resume.'`. Key order: id, ref, name, repo_id, status, step, message, hint, error_kind, started_at, finished_at, total_bytes, done_bytes, percent, speed, eta_seconds, files, steps, model. The fixture (a fake-hub live job) matches.

### GET /admin/ports
`{"ports":[view]}`, `SELECT * FROM ports ORDER BY id DESC LIMIT 20`. View: `{"id","ref","name","repo_id","status","stage","message","started_at","finished_at","max_attempts","stages":json(stages),"log":"H/ports/<id>/port.log","log_tail": last 40 lines of that file joined with "\n" ("" if missing),"model"}`. Each stage: `{"name","status","started","ended","detail","attempt"}`; stage names are workspace, skills, generate, build, parity, register, serve. At startup running rows become failed (`message='interrupted: the daemon stopped during this port. Run it again.'`). Fixture: `{"ports":[]}`.

### GET /admin/search?q=
- The raw `q` must be 200 characters or fewer, else 400 `The search text is too long.` (`invalid_query`). If the catalog can't load → 503 (message from the error, code `search_unavailable`, type `server_error`).
- Reply `{"query": q.strip(), "memory": mem, "results": [...], "warnings": [str]}`.
- **mem**: when there are GPUs, take the one with the largest (total − used): `{"basis":"gpu","name","free_gb":round((total-used)/1024,1),"total_gb":round(total/1024,1)}`. Otherwise `{"basis":"ram","name":"system RAM (no NVIDIA GPU found)","free_gb":round(MemAvailable_kB/1048576,1),"total_gb":round(MemTotal_kB/1048576,1)}` from `/proc/meminfo`.
- **catalog**: `H/max_catalog.json` (`{arch: {"example_repo_ids":[...],"supported_encodings":[...]}}`, 101 architectures here) when its mtime is less than 7 days old. Otherwise run `max list --json` (120 s timeout), take `.architectures`, and write the cache.
- **pool**: (a) the CURATED entries in order: `id`=short name, `source:"max"`, `supported:true`, `architecture` = the catalog arch whose example_repo_ids contain the repo (case-insensitive; first found when iterating the catalog in file order, else null). (b) Then every catalog architecture **sorted by name**, each example repo in order and not seen yet (case-insensitive): `id`=repo_id, `source:"max"`, `supported:true`.
- **row**: `{"id","repo_id","source","architecture","params":int|null,"size_gb","est_vram_gb","supported","fit","suggestions":[]}`.
  - `params` = params_from_name(repo_id): every match of `(?<![\w.])(\d+(?:\.\d+)?)([bBmM])(?![A-Za-z0-9])`, value × 1e9 for b/B or 1e6 for m/M, take the max, int. None found → null.
  - `size = params*2/1e9` → `size_gb = round(size,2)`; `est = size*1.2 + 1.0` (from the unrounded size) → `est_vram_gb = round(est,1)`.
  - `fit`: not supported → `"port"`; est null → null; `est <= free*0.8` → `ok`; `est <= free` → `tight`; else `no`.
- **empty q**: results = the pool rows whose id is a curated name (the 6 curated rows, in CURATED order).
- **non-empty q**: tokens = lower(q).split(). Keep rows where every token is a substring of `lower("{id} {repo_id} {architecture or ''}")`. Stable sort by (id ≠ q case-insensitively, id not curated). Keep the first 20.
- If q looks like a repo id (`owner/name`, each part `[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?`, length ≤ 96, no `..` or `--`) and no result has that repo_id: ask Hugging Face (network). Insert at index 0 `row(id=q, repo_id=q, source:"hf", architecture=config.json architectures[0], params=safetensors total or params_from_name, supported = arch in catalog AND the repo has a *.safetensors file)`. Not found or gated → no row. Network error → its message is appended to `warnings`.
- **suggestions** (only for fit = `no`): pool rows with fit `ok`, a different repo, and est < this row's est (or this row's est is null). Sorted by (different architecture first = false, est desc); take 3, keeping only `{id,repo_id,architecture,params,size_gb,est_vram_gb}`.
- The fixture (empty q) matches. The fit numbers depend on the GPU's free memory at that moment.

### GET /admin/learn/{name}
- Name not in models → 404 `The model `{name}` is not registered.` (`model_not_found`).
- `path = H/notebooks/<name>.ipynb`. If it exists and `metadata.mxconsole.architecture` is present → read it, `generated:false`. Otherwise build it from Hugging Face (network: model_info, README.md, config.json at models.revision), write it, `generated:true`. Any failure → 502 `could not build a notebook for {name}: {e}` (`learn_failed`, `server_error`).
- Reply: `{"name","path","generated":bool,"kernelspec":{"name":"python3","display_name":"Python 3","language":"python"},"architecture":<metadata.mxconsole.architecture>,"cells":[{"type":"markdown"|"code","source":str,"outputs":[]}]}` (outputs = the cell's outputs, `[]` for markdown cells).
- **architecture** = `{"architecture": config.architectures[0] | null, "rows":[{"field","value","meaning"}], "parameters": breakdown | null, "safetensors_total": int | null}` (from HF `model_info.safetensors.total`).
- **rows** (let `c = config.text_config or config`; a field is skipped when its value is null). `meaning` comes from the fixed EXPLAIN table; copy the strings from the fixture.
  | field | value |
  |---|---|
  | model_type | config.model_type |
  | architectures | `", ".join(config.architectures)` or skipped |
  | hidden_size, num_hidden_layers, num_attention_heads, num_key_value_heads | from c |
  | gqa_ratio | only when heads and kv are both set: `"{heads/kv:g}:1"`, or `"1:1 (plain multi-head)"` when equal |
  | head_dim | `c.head_dim` or `hidden // heads` |
  | intermediate_size, vocab_size, max_position_embeddings | from c |
  | rope_theta | `c.rope_theta`, else `(c.rope_scaling or c.rope_parameters).rope_theta` |
  | rope_scaling | `json.dumps(c.rope_scaling or c.rope_parameters)` when set |
  | tie_word_embeddings | `c.tie_word_embeddings`, else config's |
- **parameters** (null unless hidden h, layers L, heads, vocab V and intermediate I are all set): `kv = num_key_value_heads or heads`; `hd = head_dim or h//heads`; `E = num_local_experts or num_experts or 1`; `W = (moe_intermediate_size or I) if E>1 else I`.
  `embeddings=V*h`; `attention_per_layer = h*heads*hd + 2*h*kv*hd + heads*hd*h`; `mlp_per_layer = 3*h*W*E`; `norms_per_layer = 2*h`; `lm_head = 0 if tied else V*h`; `total = embeddings + L*(attn+mlp+norms) + h + lm_head`. Returned as `{"embeddings","attention_per_layer","mlp_per_layer","norms_per_layer","layers","lm_head","total","experts"}`. Check with Qwen2.5-0.5B: h 896, heads 14, kv 2, hd 64 → attn 1,835,008, total 494,005,120, as in the fixture.
- **cells** (13 when config.json has rows, 12 when it doesn't):
  1. md `# {name}\n\n[`{repo}`](https://huggingface.co/{repo}) on Hugging Face. Everything below came from the Hugging Face API and was generated by `mxc learn`.\n\n## What it is\n\n` + lines `- **K:** V` for Pipeline, License, Parameters (`fmt(total)`), Downloads (`1,834,521`), Likes, Revision; each line skipped when its value is empty
  2. md `## Model card\n\n` + the card text (≤ 6000 characters, cut at the last newline, plus `\n\n*(model card trimmed; the full card is on Hugging Face)*`), or `*No model card text available.*`
  3. md `## Architecture\n\nFrom `config.json`:\n\n| field | value | what it means |\n|---|---|---|\n` + `` | `k` | v | meaning | `` per row. (No config: `## Architecture\n\nNo `config.json` was available from the Hugging Face API.` and cell 4 is dropped)
  4. md `## Where the parameters live` table, rows as in the fixture: embeddings, attention/MLP per layer, attention/MLP × L, output head (`tied to embeddings, no extra weights` or `separate from embeddings`), `**estimated total**`, then the safetensors total with `estimate is {diff:+.1f}% off: ` + (`close enough to trust the table` if \|diff\| < 5 else `the estimate is off; this model has parts the formula does not know about`), where diff = (est − actual)/actual × 100. `fmt(n)`: ≥1e9 → `{n/1e9:.2f}B`, ≥1e6 → `M`, ≥1e3 → `K`, else int
  5. md `## See inside: MAX's implementation\n\n...`: the `max/pipelines/architectures/*` directories whose `*.py` contain `\b{arch}\b`
  6. md `## Try it ...` (plus a "not pulled yet" paragraph when the model isn't registered; it always is here)
  7. code setup (`BASE_URL` from MXC_/HOTFIRE_/MST_BASE_URL or `http://127.0.0.1:{PORT}/v1`, `API_KEY`, `MODEL="{name}"`)
  8.–13. md `### OpenAI client`, code; md `### Streaming`, code; md `### Raw HTTP with httpx`, code (fixed text: copy from the fixture)
- Not optional: needs network only when the .ipynb is missing or old. Jupyter is only used by `POST /admin/learn/{name}/open` (501 `jupyter_missing` / 502 `jupyter_failed`); that route mints the internal `_notebook` key.

### GET /admin/models/{name}/log
404 `model_not_found` (`The model `{name}` is not registered.`) if not registered. Body = the last **8000** bytes of `H/logs/<name>.log`, decoded as UTF-8 with replacement characters (a cut in the middle of a character gives U+FFFD); `""` if the file is missing. `text/plain; charset=utf-8`; header `X-Log-Truncated: "1"` if the file is larger than 8000 bytes, else `"0"`. A `bytes` parameter is ignored.

### GET /admin/{source}/log?bytes=N
Only `daemon` (`H/logs/daemon.log`) and `caddy` (`H/expose/caddy.log`). `bytes` default 16000, clamped to [1, 65536], a non-integer → 16000. The tail is decoded with replacement; `""` if missing; `text/plain; charset=utf-8`; **no** X-Log-Truncated. Any other source (including **`litellm`**) → the plain 404 from §0. The fixture `admin_litellm_log@bytes=8000.txt` (200, empty) came from 798ef8c, where the litellm route still existed (`H/expose/litellm.log`).

## 5. Writes (all admin-guarded; §1 first)

Body helper for labels: the body must be a JSON object with the field present and of the right type, else 400 `invalid_request_body` with the message below. Label errors: `invalid_label` / `invalid_order` → 400, `label_not_found` / `model_not_found` → 404, `label_exists` → 409.
Label name rule: `^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$`, ≤ 40 characters, else 400 `invalid_label`: `label names are lower-case letters, digits and hyphens, up to 40 characters (like `work` or `my-label`); got '{name!r}'` (Python repr, single quotes).

| Request | Effect | 200 reply | Errors |
|---|---|---|---|
| `POST /admin/labels {"name"}` | check the name; in one transaction: exists → 409; `INSERT INTO labels(name,position) VALUES(?, (SELECT COALESCE(MAX(position)+1,0) FROM labels))` | `{"name"}` | 400 `Send JSON with `name` (the new label).`; 400 invalid_label; 409 `a label named {n} already exists` |
| `PATCH /admin/labels/{old} {"name":new}` (rename) | check new; old missing → 404; new ≠ old and new exists → 409; update `labels.name` and `model_labels.label` | `{"name":new}` | 400 `Send JSON with `name` (the new name).`; 404 `no label named {old}. See: mxc labels`; 409 |
| `DELETE /admin/labels/{name}` | missing → 404; delete its model_labels, then the label | `{"name"}` | 404 |
| `PUT /admin/labels/order {"names":[str]}` | `sorted(names)` must equal the sorted list of all labels (each exactly once), else 400; `position = index` | `{"names"}` | 400 `Send JSON with `names` (every label, in the order you want).`; 400 `send every label exactly once to reorder them` (`invalid_order`) |
| `POST /admin/labels/{name}/add {"models":[str]}` | check the label name; every model must exist (the first missing one → 404); create the label if missing (even with `[]`); `INSERT OR IGNORE` each (model,label) | `{"name","models"}` (echo) | 400 `Send JSON with `models` (a list of model names).`; 400 invalid_label; 404 `no model named {m}. See: mxc ls` |
| `POST /admin/labels/{name}/remove {"models"}` | models must exist (404), the label must exist (404); delete those links | `{"name","models"}` | same, plus 404 label_not_found |
| `POST /admin/keys {"app"}` | app must fully match `[A-Za-z0-9._-]{1,64}` and not start with `_`. In `BEGIN IMMEDIATE`: an active row → 409. Else upsert `(app, prefix=key[:12], key_hash=sha256hex(key), created_at=now)`, reset last_used_at and revoked_at to NULL (this revives a revoked app). key = `"mst-" + base64url(32 random bytes, no padding)` (47 characters) | **201** `{"app","key"}` (plaintext, shown only this once) | 400 `app name '{app}' must be letters, digits, '.', '_' or '-'`; 400 `app names starting with '_' are reserved for omxconsole`; other bad bodies 400 `Send JSON like {"app": "my-app"}: letters, digits, '.', '_' or '-'.` (all `invalid_request_body`); 409 `{app} already has a key. Use --rotate to replace it (the old key stops working).` (`key_exists`) |
| `POST /admin/keys/{app}/rotate` | app starting with `_` or no row (revoked rows count) → 404. New key as above | 200 `{"app","key","revived": old revoked_at != null}` | 404 `there is no key for {app}. Create one with: mxc keys new {app}` (`key_not_found`) |
| `DELETE /admin/keys/{app}` | `UPDATE keys SET revoked_at=now WHERE app=? AND revoked_at IS NULL`; `_` app or 0 rows → 404 | `{"app","status":"revoked"}` | 404 `There is no active key for `{app}`.` (`key_not_found`) |
| `POST /admin/models/{name}/load` | ensure_running (§2.1); waits until healthy | `{"name","upstream":"http://127.0.0.1:{port}/v1"}` | 404 `The model `{name}` is not registered. Run `mxc pull {name}`.`; 503 `Model `{name}` failed to start: {reason}` (`model_unavailable`, `server_error`) |
| `POST /admin/models/{name}/stop` | not registered → 404; stop the child (a no-op when cold) | `{"name","state":"cold"}` | 404 `The model `{name}` is not registered.` |
| `POST /admin/shutdown` | stop_all children, then SIGTERM itself 0.2 s later | `{"stopping":true}` | none |

Also present, outside the requested list: `PATCH /admin/models/{name}` (`{pinned:bool, keep_alive:int>=0, kind}` → model row), `DELETE /admin/models/{name}?purge=1` (→ `{"name","removed":true,"graph_cache_deleted","purged","purged_path","purge_note"}`; the 798ef8c version also had `lan_refreshed`), `POST /admin/bench`, `POST /admin/pulls`, `POST /admin/ports`, `/admin/expose`, `/admin/status` (= supervisor status array), `/admin/insights`, `/admin/try/chat`, `/admin/try/complete` (the Mojo daemon, D-6418: `{model, prompt, max_tokens?}` → a `/v1/completions` reply, for a ported base model's smoke test).

## 6. The /v1 gateway

| Route | Auth | Reply |
|---|---|---|
| `GET /health` | none | `{"status":"ok","service":"mst"}` |
| `GET /auth/check` | key | 200, empty body, header `X-Mst-App: <app>`; 401 empty body (logged with route `auth_check`) |
| `GET /v1/models` | key | `{"object":"list","data":[{"id":name,"object":"model","created":0,"owned_by":"omxconsole","mxconsole":{"state","repo_id","pinned","keep_alive"}}]}`, models by name (logged: route `models`, model null, 200 or 401) |
| `POST /v1/chat/completions` · `/v1/completions` · `/v1/embeddings` | key | proxied (routes `chat`, `completions`, `embeddings`) |
| anything else under `/v1/` (any method, including `POST /v1/models` and `GET /v1/chat/completions`) | key | counts `unknown_route`; then 401, or 404 `omxconsole does not serve /v1/{path}. Supported: /v1/models, /v1/chat/completions, /v1/completions, /v1/embeddings.` (`unknown_route`). Not logged |

**Key check**: `Authorization: Bearer <token>` (scheme case-insensitive, token trimmed; no header means no key) → `SELECT app, last_used_at FROM keys WHERE key_hash = sha256hex(token) AND revoked_at IS NULL`. Found → if last_used_at is NULL or now − last_used_at ≥ 60 → `UPDATE keys SET last_used_at=now WHERE app=?`. Internal `_` keys work here too (bench, notebook).
**401** body: `{"error":{"message":"Incorrect API key provided. Create one with `mxc keys new <app>`.","type":"authentication_error","param":null,"code":"invalid_api_key"}}`.

**Proxy steps** (with `started = monotonic()` at arrival):
1. No key → log(app null, model null, 401) → 401.
2. Body must be a JSON object with a string `model`, else log(app, null, 400) → 400 `Request body must be JSON with a string `model` field.` (`invalid_request_body`).
3. Drop unknown top-level fields: the allowed set comes from MAX's pydantic schema (`max.serve.schemas.openai.Create{Chat,}CompletionRequest` / `CreateEmbeddingRequest`, only when `extra=='forbid'`). Never dropped: `tools, tool_choice, functions, function_call, response_format, logprobs, top_logprobs, n, seed, stop`. When fields are dropped, the body is re-serialised and the reply gets the header `x-mxc-dropped-params: a,b,...` (names matching `[A-Za-z0-9_.-]{1,64}`, at most 20, then `+N more`). If the schema can't be read → pass the body through unchanged. **New since 798ef8c.** A Mojo port without Python can skip this (pass-through) or hard-code the field lists.
4. Model name = the `model` string, exactly; it must equal `models.name` (no alias or repo_id lookup). ensure_running: unknown → log(app, name, 404) → 404 `The model `{name}` is not registered. Run `mxc pull {name}`.` (`model_not_found`); start failure → log 503 → 503 `Model `{name}` failed to start: {reason}` (`model_unavailable`, `server_error`). A cold start blocks the request until the child is healthy.
5. Reset `started = monotonic()` (a cold start is never part of TTFT or duration). `in_flight++`.
6. `POST http://127.0.0.1:{port}{path}` (same path, `/v1/...`), raw body, headers `content-type` (the client's, default `application/json`) and `accept-encoding: identity`. No read timeout; 10 s connect timeout. Transport error → log 502 → 502 `Model `{name}` is not answering: {e}` (`bad_gateway`, `server_error`).
7. Stream the upstream reply back unchanged: the same status (upstream 4xx/5xx bodies pass through as is) and its headers minus `content-length, transfer-encoding, connection, content-encoding`.
8. When the stream ends (or the client disconnects): `in_flight--`, then log.

**Request log** = `INSERT INTO requests (ts, app, model, route, status, prompt_tokens, completion_tokens, ttft_ms, duration_ms, estimated)`:
| column | value |
|---|---|
| ts | `time.time()` **when the row is written** (the end of the request), not arrival |
| app | key's app; null for 401; `console` for `/admin/try/chat` |
| model | requested name; null for 401 and 400 and `/v1/models` |
| route | `chat`, `completions`, `embeddings`, `models` or `auth_check` |
| status | upstream status, or the gateway's own 400/401/404/502/503 |
| prompt_tokens | the meter's value (below); null for early errors |
| completion_tokens | the meter's value; null for early errors |
| ttft_ms | **streamed only** (upstream content-type contains `text/event-stream`): (first upstream byte chunk − started) × 1000; else null |
| duration_ms | (now − started) × 1000; for early errors from arrival, for proxied requests from step 5 |
| estimated | 1 only for streamed replies without a `usage.completion_tokens`; else 0 |

Meters:
- **Streamed** (SSE): split on `\n\n`; for each `data:` line other than `[DONE]`, parse JSON. If `usage` is an object → `prompt_tokens = usage.prompt_tokens` and `usage_completion = usage.completion_tokens`. A chunk "generated" if any choice has a truthy `text`, or a `delta` with a truthy `content`, `reasoning_content`, `reasoning` or `tool_calls`; it then adds `token_count` (if an int > 0) else 1 to `chunks`. completion_tokens = usage_completion if present, else chunks. An event larger than 256 KB is dropped.
- **JSON** (anything else): buffer up to 1 MB; at the end read `usage.prompt_tokens` and `usage.completion_tokens` (null if missing, too big or not JSON). estimated = false.
- Embeddings replies are JSON: completion_tokens comes from usage (usually absent → null).

Recording errors never fail a request. Retention: 7 days (§2.2).

## 7. Curated models (`resolve.CURATED`), used by search, pulls and learn

| id | repo_id | catalog arch (fixture) | params (from the name) | size_gb | est_vram_gb |
|---|---|---|---|---|---|
| qwen2.5-0.5b | Qwen/Qwen2.5-0.5B-Instruct | Qwen2ForCausalLM | 500000000 | 1.0 | 2.2 |
| qwen2.5-1.5b | Qwen/Qwen2.5-1.5B-Instruct | Qwen2ForCausalLM | 1500000000 | 3.0 | 4.6 |
| qwen2.5-3b | Qwen/Qwen2.5-3B-Instruct | Qwen2ForCausalLM | 3000000000 | 6.0 | 8.2 |
| smollm2-1.7b | HuggingFaceTB/SmolLM2-1.7B-Instruct | LlamaForCausalLM | 1700000000 | 3.4 | 5.1 |
| llama3.2-1b | meta-llama/Llama-3.2-1B-Instruct | LlamaForCausalLM | 1000000000 | 2.0 | 3.4 |
| all-minilm-l6 | sentence-transformers/all-MiniLM-L6-v2 | BertModel | null | null | null |

There are no other fields: CURATED is a plain `{short: repo_id}` map (serialised as is in `/admin/pulls.curated`, in this order). The architecture and size are derived at search time. Pull naming: a curated ref → its short name; a repo that is a curated value → that short name; else the lower-cased last part of the repo.

## 8. Optional / removed dependencies

| Dependency | Status | When off |
|---|---|---|
| LiteLLM | **removed** at F-063 (after 798ef8c) | no crew or listener row, no `expose.litellm` or `ports.litellm`, `/admin/litellm/log` and `/admin/litellm/restart` → 404. `expose.stop()` still kills a leftover `litellm.pid` and revokes `_litellm` |
| Caddy | optional (`mxc expose`) | crew `stopped`, listeners `off`, `lan_endpoint` and `tls.endpoint` null, `exposed` false; `enforced_by_caddy` is constant anyway |
| Jupyter | optional | only `POST /admin/learn/{name}/open` (501/502); GET learn doesn't need it |
| nvidia-smi | optional | `gpus:[]`, `gpu:null`, `vram_gb:null`, search memory falls back to RAM, no `--devices`, memory fraction `0.35` |
| Hugging Face network | optional | learn for a missing notebook → 502; search repo-id lookup → a warning, no row |
| `max list` | needed for search when there is no cache less than 7 days old | 503 `search_unavailable` |
| MAX Python schema | optional | no parameter dropping; bodies pass through |

## 9. Fixture vs current code (fixture recorded at 798ef8c)

| Reply | Difference |
|---|---|
| /admin/system | the fixture has the LiteLLM crew row and listener, and the old daemon `talks_to`; current has neither and the new text (§4) |
| /admin/network | the fixture has `expose.litellm` and `ports.litellm` (4000); current drops both |
| /admin/litellm/log | fixture 200 `""`; current **404** `404 Not Found` |
| /admin/models | the `source:"huggingface"` values are seeded; real rows say `max-catalog`, `hf-supported` or `port`. Keys identical |
| /admin/pulls | `fake_hub:true` appears only in test mode |
| /admin/system logs | no `daemon` entry because the recording home had no daemon.log |
| /v1 replies | the `x-mxc-dropped-params` header is new |
| DELETE /admin/models/{name} | `lan_refreshed` removed |
| all others (info, models, labels, keys, gateway, metrics, series, requests, bench, bench/history, ports, search, learn, model log) | the shapes match the current code |
