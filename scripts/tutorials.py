"""The tutorials can't go stale: every code block on a tutorial page that names its file is that file's text, and each
tutorial's app builds and does what its page says, on GTK, the web and through the agent host (D-4761).

  pixi run python scripts/tutorials.py          (all of it: ~3 min, most of it the builds)
  pixi run python scripts/tutorials.py --shots  (also retakes the pages' pictures, docs/img/tasks/)

A block is checked when its <pre> has data-file="examples/<app>/app.mojo": its text (tags stripped, entities
unescaped) must be a run of that file's lines as they are (with their common indent removed, so a part from inside a
method can start at the margin), so a page can show a part of a file but never a version of it. Every page
has at least one. A <pre data-output="gtk|agent"> shows what the app printed: each of its output lines (the
<span class="o"> parts) must be a line the check's own run printed.
"""

import html
import os
import re
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import headless  # noqa: E402
from drive import web_run  # noqa: E402
from agent_client import Client  # noqa: E402

PAGES = ["docs/start.html", "docs/tasks.html", "docs/learn/index.html"]
FIELD = "What needs doing?"
STEPS = f"type:{FIELD}=Buy milk;tap:Add;type:{FIELD}=Call Ada;submit:{FIELD};toggle:Buy milk"
AFTER = ["CHECK: Buy milk=on", "CHECK: Call Ada=off", "LABEL: 1 left"]


def blocks(page):
    """(file, text) for each <pre data-file=…> on the page."""
    src = (ROOT / page).read_text()
    for m in re.finditer(r'<pre[^>]*\bdata-file="([^"]+)"[^>]*>(.*?)</pre>', src, re.S):
        yield m.group(1), html.unescape(re.sub(r"<[^>]+>", "", m.group(2)))


def is_part_of(text, path):
    """text is a run of whole lines of the file at path, give or take the run's common indent."""
    want = textwrap.dedent(text).strip("\n").split("\n")
    have = (ROOT / path).read_text().split("\n")
    n = len(want)
    return any(textwrap.dedent("\n".join(have[i:i + n])).split("\n") == want for i in range(len(have) - n + 1))


def code_matches():
    bad, n = [], 0
    for page in PAGES:
        if not list(blocks(page)):
            bad.append(f"{page}: no <pre data-file=…> block")
        for file, text in blocks(page):
            n += 1
            if not is_part_of(text, file):
                first = next((l for l in text.splitlines() if l.strip() and l not in (ROOT / file).read_text()), "?")
                bad.append(f"{page}: a block isn't {file}'s text (first line that differs: {first.strip()!r})")
    return n, bad


def shown_output(page, kind):
    """The output lines a page shows in its <pre data-output=kind> blocks (None: it has none)."""
    src = (ROOT / page).read_text()
    found = re.findall(rf'<pre[^>]*\bdata-output="{kind}"[^>]*>(.*?)</pre>', src, re.S)
    if not found:
        return None
    spans = [sp for block in found for sp in re.findall(r'<span class="o">(.*?)</span>', block, re.S)]
    return [html.unescape(l).strip() for sp in spans for l in sp.splitlines() if l.strip()]


def output_shown(page, kind, printed):
    """Problems: a line the page shows that the run didn't print."""
    lines = shown_output(page, kind)
    if lines is None:
        return [f"{page}: no <pre data-output=\"{kind}\"> block"]
    got = {l.strip() for l in printed.splitlines()}
    return [f"{page}: shows {l!r}, which the {kind} run didn't print" for l in lines if l not in got]


def build(app, host):
    r = subprocess.run(["scripts/build.sh", app, host], cwd=ROOT, capture_output=True, text=True)
    return None if r.returncode == 0 else f"{app} {host} doesn't build: " + (r.stdout + r.stderr)[-600:]


def gtk(app, steps, config, shot=None):
    env = dict(os.environ, OMX_CONFIG=config, MOJOUI_TEST=steps or "pause:100")
    if shot:
        env.update(MOJOUI_SHOT=shot, MOJOUI_WINDOW="520x420")
    r = subprocess.run([f"build/{app}/linux/{app}"], cwd=ROOT, env=env, capture_output=True, text=True, timeout=300)
    return r.stdout


def lacks(out, want):
    return [w for w in want if w not in out.splitlines()]


def main():
    shots = "--shots" in sys.argv
    problems = []
    n, bad = code_matches()
    problems += bad
    print(f"code blocks: {n - len(bad)} of {n} are their files' text")

    for app, host in [("start", "linux"), ("tasks", "linux"), ("tasks", "web")]:
        err = build(app, host)
        if err:
            problems.append(err)
    if problems:
        return problems
    headless.ensure()

    # start: three taps
    with tempfile.TemporaryDirectory() as cfg:
        out = gtk("start", "tap:Tap me;tap:Tap me;tap:Tap me", cfg)
        problems += [f"start on GTK: no {w}" for w in lacks(out, ["LABEL: Tapped 3 times"])]

    # tasks on GTK: add two, tick one; then the app again, from its database
    img = ROOT / "docs/img/tasks"
    img.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as cfg:
        out = gtk("tasks", STEPS, cfg)
        problems += [f"tasks on GTK: no {w}" for w in lacks(out, AFTER)]
        problems += output_shown("docs/tasks.html", "gtk", out) + output_shown("docs/learn/index.html", "gtk", out)
        again = gtk("tasks", "", cfg, shot=str(img / "tasks-gtk.png") if shots else None)
        problems += [f"tasks on GTK, reopened: no {w}" for w in lacks(again, AFTER)]
        out = gtk("tasks", "tap:Remove", cfg)
        problems += [f"tasks on GTK, Remove: no {w}" for w in lacks(out, ["CHECK: Call Ada=off", "LABEL: 1 left"])]
        if "CHECK: Buy milk=on" in out:
            problems.append("tasks on GTK: Remove left Buy milk")
    print("tasks on GTK: add, tick, reopen, remove")

    # tasks on the web: the same steps, the same screen
    with tempfile.TemporaryDirectory() as cfg:
        r, out = web_run("build/tasks/web", STEPS, shot=str(img / "tasks-web.png") if shots else None, viewport=(520, 420),
                         env=dict(os.environ, OMX_CONFIG=cfg))
        problems += [f"tasks on the web: no {w}" for w in lacks(out, AFTER)]
    print("tasks on the web: add, tick")

    # tasks through the agent host: what the page shows it doing
    with tempfile.TemporaryDirectory() as cfg:
        c = Client("build/tasks/web", env=dict(os.environ, OMX_CONFIG=cfg))
        try:
            added = c.call("what-needs-doing", text="Buy milk", submit=True)[0]
            added += "\n" + c.call("what-needs-doing", text="Call Ada", submit=True)[0]
            before, _, _ = c.call("screen")
            refused, _, err = c.call("buy-milk")
            if not err:
                problems.append("agent: buy-milk without \"on\" wasn't refused")
            said, _, _ = c.call("buy-milk", on=True)
            screen, _, _ = c.call("screen")
        finally:
            c.close()
        printed = "\n".join([added, before, refused, said, screen])
        problems += output_shown("docs/tasks.html", "agent", printed) + output_shown("docs/learn/index.html", "agent", printed)
        for want in ['Checkbox "Buy milk" = on → buy-milk', "remove-2 — Remove Call Ada", '"1 left"']:
            if want not in screen:
                problems.append(f"agent: the screen lacks {want!r}")
        if "Now: 1 left" not in said:
            problems.append(f"agent: buy-milk said {said!r}")
    print("tasks by an agent: add, tick, a call without its value refused")
    return problems


if __name__ == "__main__":
    problems = main()
    for p in problems:
        print("FAIL", p)
    print("PASS" if not problems else f"FAIL ({len(problems)})")
    sys.exit(1 if problems else 0)
