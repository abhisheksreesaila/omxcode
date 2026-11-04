# Post series: start simple (owner, 2026-11-04)

The owner: the first posts were too heavy. Start with what the framework is and how to begin; then that every app is
agent-ready; then agents building screens; then omxplorer, the piece built with all of it. One idea, one picture, one
link per post, under 280 characters. Drafts for the owner to post (nothing is posted from here). The links work once
goal 48 is merged and the site is pushed: docs/start.html and docs/agents.html are new.

Pictures are in `docs/launch/series/`.

---

## 1 · What it is, and how to start

> omxcode: write an app in Mojo, run it natively.
>
> One file becomes a native Linux app and a web app. 30 lines, one build command, and the Liquid look is one method.
>
> Your first app in ten minutes: https://abhisheksreesaila.github.io/omxcode/start.html

Picture: `1-hello-liquid.png` (the same app with no theme, then with `return liquid()`). 219 characters as X counts them (a link is 23).

## 2 · Every app is agent-ready

> Every omxcode app is also a set of tools for an AI agent. No extra code.
>
> A button called "Tap me" becomes a tool called tap-me. The agent reads the screen as text and taps it, and can't do
> anything you couldn't.
>
> https://abhisheksreesaila.github.io/omxcode/start.html#agent

Picture: `2-agent-tools.png` (real output: `screen`, then `tap-me` → "Now: Tapped 1 times"). 237 characters.

## 3 · Agents answer with screens

> And agents can answer with screens.
>
> Ask "plan a day in Lisbon" and get a map, a timeline and a weather chart, drawn natively from 36 components. Standard
> AG-UI, or the agent inside the app.
>
> https://abhisheksreesaila.github.io/omxcode/agents.html

Picture: `3-agent-screens.png` (the Lisbon trip). 215 characters.

## 4 · What it builds

> Built with all of it: omxplorer, a data app written in Mojo.
>
> A spreadsheet, the video behind each row and the documents that explain it, on one page, on your own machine.
>
> https://abhisheksreesaila.github.io/omxcode/omxplorer.html

Picture or clip: `docs/img/clip-robots-15s.mp4` (the robot-failure story, already made for the launch). 192 characters.

---

Notes for the owner:
- Posts 1 to 3 make no speed claims (D-4749); post 4 keeps omxplorer's page as it is.
- Every command and screen in posts 1 and 2 was run for this: `examples/start` built on GTK and the web, driven through
  the agent host (`pixi run python scripts/agent_client.py build/start/web tap-me`).
- Post 1's "Mac" is left out on purpose: Mac builds run on GitHub's machines, not yet on someone's own Mac.
