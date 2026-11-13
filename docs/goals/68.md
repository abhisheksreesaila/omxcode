# GOAL 68: add a model like magic, and open a robot fleet's bags (part 1: small, simple, polished)

**End goal (owner, 2026-11-12):** options B and C from the robotics shortlist, with AI applied. "These models need to be
a plugin… develop a plugin to omxplorer to add models (and forget omxconsole)… right now omxplorer takes precedence…
plugin a model so easily and it should feel like magic… [it] could be decision models to categorize tabular data…
Simple (but useful) models… Data (not large), get the features done… polish and ease of use… once we agree, then
enlarge and shoot a video… it has to be sexy."

So this goal is **part 1**: the features, small and polished. Simple models (decision trees, the small vision models we
have), small data (a few bags). Part 2 (big video and vision-language models, the full fleet, training a policy, the
film) starts only after the owner has tried part 1 and agreed.

Base: origin/main a52aa958. Worktree ../mojo-ui-g68, branch goal-68-models-and-bags. Decisions D-68xx.

## Milestones
| # | Milestone | Proof (`docs/goals/68-check.py`; PASS, FAIL or BLOCKED each) |
|---|---|---|
| M0 | One plugin format | `mojoui.plugins`: a model plugin is a folder with `plugin.json` (kind = tabular · detect · segment · classify-image · embed-text; inputs; outputs as columns; runner = tree, MAX pack, or the in-process torch runner as `visionmodel_torch.py` is today). Decision models load from XGBoost JSON, LightGBM text, ONNX or skops; never pickle. OWLv2, YOLOX, e5 and the image-label packs move onto it, with no per-model Mojo left. A test plugin dropped into the folder works with no rebuild |
| M1 | Learn from my labels | in any table: label about 20 rows (a new column, typed in or picked), press **Learn**, and a decision tree (in Mojo, on the data where it is) fills the rest. It says its rule in words ("stopped when speed < 0.1 and a person is within 1.5 m"), shows how sure it is per row, and its accuracy on labelled rows it never saw. Change a label and it relearns in under a second on 100k rows. The agent can do the same (`learn` tool) |
| M2 | Add a model, like magic | **Add a model**: paste a Hugging Face name, drop a folder or a model file, or ask the agent (`add-model`). One line before any download says what it does, whether it fits the GPU, and its licence; a model that can't run says why, then nothing downloads. It downloads with progress and **answers on the row or frame you were looking at** the moment it lands; then "Run it on all N?" fills a column as answers come. A tabular model's columns are matched by name and type, a mismatch shown, never guessed. Code inside a model (`trust_remote_code`) runs only after a yes for that model. Proof: a stopwatch from paste to first answer for 4 models of 4 kinds not seen before (a tree file, an image classifier, a detector, a text embedder), each under 2 minutes after download, reported |
| M3 | ROS 2 bags, read in Mojo | `mojoui.bag`: MCAP (records, chunk index, zstd/lz4 over FFI) and rosbag2 sqlite3, CDR decoded from the schemas the file carries (no ROS install). Topics become tables with a time column; camera topics become video tables. Small data: 3 to 6 short bags from NavWareSet and NVIDIA r2b 2024 (both CC BY 4.0, licence confirmed and noted). 1,000 messages per topic match the official `mcap` + `rosbags` Python readers field for field |
| M4 | A fleet in one sheet | open a folder of bags: one row per run (robot, duration, distance, stops, topics), every topic joined on time, every camera on one cursor, a `story.json` written for it with a few questions. Then label 20 stops and Learn (M1) names the cause of the rest |
| M5 | Polish and ease of use | the four flows (learn, add a model, open bags, the fleet) each done by a person in under a minute with no docs: the first screen says what to do, every wait shows progress, every error says what to do next, nothing reflows when answers arrive, omxqua throughout. Proof: each flow driven by the agent over MCP and in headless Chromium on the web host, screenshots of every state (empty, loading, done, error) looked at, and the reviewer's ease-of-use pass |
| M6 | Nothing regressed | goal 47's check, goal 59's packs, goal 62's starter, `scripts/check` |

## Done means
68-check PASS for M0–M6; the reviewer passes every milestone, and the security auditor passes M0 and M2 (code and
weights from outside, run in the app's process); README's model table gains plugins and Learn; docs/models.html
updated; `docs/goals/68-report.md` with the screenshots and the stopwatch numbers; EXPERIMENTS.md. Then stop and show
the owner. Merged and pushed only after their yes.

## Part 2, after the owner agrees (not this goal)
Bigger models through the same Add a model (Cosmos-Embed1 for "moments like this", a vision-language model for "why did
it stop?"), the full fleet, cleaning LeRobot demos and training a policy on raw vs cleaned, and the film.

## Out of bounds
GR00T weights (NVIDIA OneWay Noncommercial); large downloads (over 2 GB of data in total; models over 2 GB); omxconsole
(owner: omxplorer first); deploying; pushing; pip (pixi only); the frozen ../mojo-ui-apple-test and other worktrees;
lowering a proof or deleting a test.

## Assumptions (taken instead of asking)
- Plugins run in omxplorer's process, beside the data; `plugin.json` is written so omxconsole could host the same folder later.
- The decision tree is written in Mojo (CART, depth-limited, so its rule fits in a sentence); imported tree files are
  evaluated in Mojo where the format allows (XGBoost JSON, LightGBM text), ONNX through onnxruntime.
- If a bag dataset's download is larger than the limit, take the smallest scenes, never the whole set.
