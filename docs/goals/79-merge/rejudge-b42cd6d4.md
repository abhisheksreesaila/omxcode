# The merged code's race (b42cd6d4) judged again with D-8097's tie at the measured refresh

goal 79's docs/goals/79/rejudge.py, unchanged, run from a scratch folder holding the current 79-check.py and these two tables at the paths it reads (race.md = race-linux-b42cd6d4.md at 60 Hz, race-mac.md = race-mac-b42cd6d4.md at 144 Hz). Linux **60 ✓ 0 ✗**; Mac **52 ✓ 8 ✗** (it was 60 ✓ under the old 60 Hz tie).

```
== docs/goals/79/race.md at 60 Hz
  rows changed: 0
== docs/goals/79/race-mac.md at 144 Hz
  600 | redo, not warmed (latency) | web 9.0 / 9.0 | native 8.8 / 10.4 | was: ✓ tie at the display's refresh → now: ✗ worse than the web
  stress | zoom from 30% (frames) | web 8.2 / 48.6 (3) | native 9.0 / 13.9 (0) | was: ✓ tie at the display's refresh → now: ✗ worse than the web
  stress | zoom from 30%, not warmed (frames) | web 8.2 / 48.6 (3) | native 8.6 / 13.9 (0) | was: ✓ tie at the display's refresh → now: ✗ worse than the web
  stress | drag one (frames) | web 7.7 / 8.7 (0) | native 7.0 / 9.1 (0) | was: ✓ tie at the display's refresh → now: ✗ worse than the web
  stress | undo (latency) | web 8.8 / 18.8 | native 13.9 / 15.1 | was: ✓ tie at the display's refresh → now: ✗ worse than the web
  stress | undo, not warmed (latency) | web 8.8 / 18.8 | native 13.1 / 14.9 | was: ✓ tie at the display's refresh → now: ✗ worse than the web
  stress | redo (latency) | web 7.2 / 7.4 | native 15.1 / 17.1 | was: ✓ tie at the display's refresh → now: ✗ worse than the web
  stress | redo, not warmed (latency) | web 7.2 / 7.4 | native 16.0 / 16.6 | was: ✓ tie at the display's refresh → now: ✗ worse than the web
  rows changed: 8
```
