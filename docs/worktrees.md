# Worktrees: what's still checked out, and why

Cleaned up on 2026-10-31: 67 worktrees whose work was already on `main` and had nothing uncommitted were removed
(`git worktree remove`; their branches are kept, so any of them can be checked out again). What's left:

| Worktree | Branch | Status | What to do with it |
|---|---|---|---|
| `mojo-ui-omxcode` | `main` | **the place to work**; pushed | keep |
| `mojo-ui-apple-test` | detached at 3acbbb6 | frozen: the owner's Apple test builds | never touch |
| `mojo-ui-g44` | `goal-44-recall` | **not merged**: Recall, search by meaning (21 commits, review round 1 passed) | merge into main (gives `mojoui.vectors`, `mojoui.meaning`) |
| `mojo-ui-vision` | `goal-46-vision` | **not merged, parked**: `mojoui.vision` started; see docs/goals/46-RESUME.md | keep until vision resumes |
| `mojo-ui-localsql` | `localsql-mojo` | **not merged**: a SQL client over LocalSQL's Python engine (2026-10-21) | decide: merge or drop |
| `mojo-ui-mojo12` | `probe-mojo12` | **not merged**: notes on Mojo 1.2 + flare 0.13 (HTTPS lives there), uncommitted pixi changes | keep until the Mojo 1.2 move |
| `mojo-ui-site` | `data100m` | merged, but **uncommitted** `docs/briefs/` and `docs/design/omxlabs/` | look at those files before removing |
| `mojo-ui` | `engine-321870f` | old branch; uncommitted README edit (already on main) and `docs/research/max-pytorch.md` | move the research note to main, then switch this checkout to main or remove |
| `mojo-ui-g43` | `goal-43-dictate` | merged; one regenerated screenshot | remove |
| `mojo-ui-f138`, `mojo-ui-goal13` | old feature branches | merged; only an untracked `.pixi` link | remove |
| `.abode/…/t3-1376de19` | `t3/fix-open-probe-items` | merged (the probe fixes); one regenerated screenshot | remove |
| `.abode/…/t3-828a9b57` | `engine-23edc59` | merged; 23 uncommitted files from an old engine update | remove after a glance |
| `.abode/…/t3-b5fb6548` | `regression-2026-10-28` | merged; 25 regenerated bench files and screenshots | remove |

| `.abode/…/t3-32644b84` | `t3/robot-story-droid-data` | merged (goal 47); **holds `build/g47/full`** (13 GB of prepared DROID fleet data; the main checkout's `build/g47/full` links to it) | keep until the data moves |

Rule from now on: a goal's worktree is removed once its branch is merged into `main`.
