# Goal 49's story: one script over everything (15 clips)

One arc, cut into short clips (owner, 2026-11-04: "story is more important… at least fifteen videos"). Each beat follows
the clip rules (captions first, zoom one card, freeze the payoff; never a shrunk full-window recording). Every beat is
driven through agent tools only; `tool:` names the tool(s) the agent calls (a `*` stands for a card's own name).
Beats 4, 12 and 13 show models (YOLOX `detect`, a System 1 `classify`): their functions arrive in goal 50; the tools
that drive them are this goal's (the script runs whatever the registry has).

## 1. The fleet opens
caption: 63,000 robot episodes. 17 million rows of telemetry. One app.
zoom: the fleet sheet and its row count
payoff: the status bar's row count, ready in seconds
tool: `screen`

## 2. A video is a table
caption: Every video on the board is a table. One row per frame.
zoom: the Script window, then the new `frames` card
payoff: `frames` reads 244 rows, the same as the clip's frames
tool: `script`
tool: `script-text`
tool: `run-script`

## 3. Join video, telemetry and the fleet
caption: One script joins the video to the robot's telemetry and to the fleet.
zoom: the `joined` card beside the player
payoff: each frame's gripper and speed, and the lab that ran it
tool: `script-text`
tool: `run-script`
tool: `table-*`

## 4. The model shelf
caption: Models are functions. Pick one and it's in the script.
zoom: the Apply menu on the video card
payoff: the function's name written into the script
tool: `apply-regions`

## 5. Pick a section, Apply
caption: Pick a few seconds of video. Apply. The answer is there.
zoom: the range on the video card, then the result card
payoff: the result's rows, all inside the picked seconds
tool: `range-from`
tool: `range-to`
tool: `apply-regions`

## 6. Scrub through it
caption: Scrub, and the answer follows the playhead.
zoom: the player with its overlay
payoff: the boxes on the frame under the playhead
tool: `table-*`

## 7. The model's output is a column
caption: What the model saw is a column like any other: chart it beside the gripper.
zoom: the joined card's chart
payoff: detections and gripper force on one time axis
tool: `script-text`
tool: `run-script`

## 8. The whole fleet, in one statement
caption: Ask it of every episode, not one.
zoom: the answer card over the fleet
payoff: the episodes where the gripper closed and reopened, out of 63,000
tool: `script-text`
tool: `run-script`

## 9. Cut and export for a colleague
caption: Cut the section. Export the clip, the tables and the script.
zoom: the export folder
payoff: one folder: clip.mp4, the CSVs, script.sql
tool: `export-recipe`

## 10. The colleague reruns it
caption: Your colleague opens the recipe on their own robot's video.
zoom: the recipe's question (which episode?) and the new answers
payoff: the same script, a different episode, fresh numbers
tool: `open-recipe`
tool: `run-script`

## 11. An agent writes the script
caption: An agent writes the script. You watch, and say yes.
zoom: the Script window filling in
payoff: the agent's script running, its result a card
tool: `script-text`
tool: `run-script`

## 12. Supply chain: 50 million rows
caption: Another day, another table: 50 million purchase lines to classify.
zoom: the purchase sheet
payoff: the row count
tool: `screen`

## 13. A decision model, no training
caption: classify(description) with a model that already knows the world. Unsure rows go to a person.
zoom: the classified card and its confidence column
payoff: rows per second, and how few need a person
tool: `script-text`
tool: `run-script`

## 14. Your own step, on the GPU
caption: Need a step no control has? Write it. It runs on the GPU.
zoom: the script with its statement
payoff: the answer, and how long it took
tool: `script-text`
tool: `run-script`

## 15. One program
caption: The window, the GPU, the models and the agent: one Mojo program.
zoom: the whole board, then the build's one binary
payoff: the same script on Linux, the web and Mac
tool: `screen`
