# YouTube 5 · Agents drive the app (MCP and AG-UI)

**Length:** about 5 min · **Record:** Claude Code + omxplorer side by side; `examples/agentchat` · **Post:** Fri Nov 6

## Titles (≤ 60 characters)
1. My app has no API, and agents use it anyway (MCP)
2. Every button is an agent tool: MCP and AG-UI in Mojo
3. Claude drives a robot-data app with no screenshots

**Thumbnail:** `[shot: mcp-tools]` beside the app; big text **THE AGENT CLICKS NOTHING**; small: `every button is a tool`.

## Script

| Time | On screen | Say |
|---|---|---|
| 0:00 | An agent clicking pixels (any computer-use demo) vs the tool list | "Most agents use an app like a tourist with a menu they can't read: a screenshot, a guess, a click. Here's the other way." |
| 0:20 | `scripts/agent.sh omxplorer`, then `claude mcp add …` | "One command prints one line. Run it, and Claude Code sees omxplorer as a set of tools." |
| 0:45 | `[shot: mcp-tools]` | "Where do the tools come from? The screen. The same view tree that becomes GTK widgets becomes MCP tools. A button's tag names the tool, its tooltip describes it, calling it is tapping it. I wrote nothing per app." |
| 1:20 | `[clip: agent-drives]` | "Watch. I ask it which failures look like a bad grasp. It opens the fleet sheet, filters, asks the question, opens the episode. The window moves on its own." |
| 2:10 | The call log: `Did ask. Now: …` | "Each call answers in words: what changed, what opened, which tools appeared. No comparing screenshots." |
| 2:35 | A dialog open, then closed; the tool list changes | "And it's safe by construction. A disabled button isn't a tool. A dialog's buttons exist only while it's open. The agent can do nothing you couldn't." |
| 3:05 | `[clip: agui-chat]` | "The other direction is AG-UI: the agent sends data, the app builds the interface. Here it streams words, then builds a chart and a form, drawn natively, no web view." |
| 3:45 | llms.txt page | "One honest note: agents don't know Mojo yet. It's new. To write omxcode apps, they read our docs, which ship as llms.txt, and they run the checks." |
| 4:10 | Repo | "Every omxcode app is an MCP server from its first line. Links below." |

## Description

```
omxcode apps have no separate API for agents: the view tree becomes MCP tools. A button's tag names its tool, its tooltip describes it, and calling it is tapping it. A disabled button isn't a tool, so an agent can do nothing a person couldn't. Each call answers in words with what changed. Plus AG-UI: an agent streams words and builds native UI (a chart, a form).

Shown with Claude Code driving omxplorer on real robot data (DROID).

Agent docs: https://github.com/abhisheksreesaila/omxcode/blob/main/docs/agent.md
For agents writing apps: https://abhisheksreesaila.github.io/omxcode/llms.txt
Code: https://github.com/abhisheksreesaila/omxcode
AG-UI: https://docs.ag-ui.com/

Chapters
0:00 Screenshots vs tools
0:20 One command to connect
0:45 Where the tools come from
1:20 The agent drives the robot app
2:10 Answers in words
2:35 Safe by construction
3:05 AG-UI: the agent builds the screen
3:45 Agents and Mojo, honestly
4:10 Try it
```

**Tags:** MCP, Model Context Protocol, AG-UI, AI agents, Claude Code, agent tools, generative UI, Mojo, app framework, omxcode, omxplorer, robotics data

*Sources: S11, S12, S20. The robot-data agent session is tonight's build: use whatever the recorded agent actually asked.*
