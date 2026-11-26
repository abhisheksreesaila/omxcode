# Continuation 28: the race tables judged again with the tie at the measured refresh (docs/goals/79/rejudge.py, D-8097)

```
== docs/goals/79/race.md at 60 Hz
  rows changed: 0
== docs/goals/79/race-mac.md at 144 Hz
  600 | redo, not warmed (latency) | web 9.0 / 9.0 | native 8.7 / 11.4 | was: ✓ tie at the display's refresh → now: ✗ worse than the web
  stress | zoom from 30% (frames) | web 8.5 / 48.6 (2) | native 9.1 / 10.6 (0) | was: ✓ tie at the display's refresh → now: ✗ worse than the web
  stress | drag one (frames) | web 7.1 / 8.8 (0) | native 7.0 / 11.0 (0) | was: ✓ tie at the display's refresh → now: ✗ worse than the web
  stress | drag one, not warmed (frames) | web 7.1 / 8.8 (0) | native 7.0 / 12.1 (0) | was: ✓ tie at the display's refresh → now: ✗ worse than the web
  stress | undo (latency) | web 8.9 / 13.0 | native 14.4 / 14.9 | was: ✓ tie at the display's refresh → now: ✗ worse than the web
  stress | undo, not warmed (latency) | web 8.9 / 13.0 | native 16.5 / 17.5 | was: ✓ tie at the display's refresh → now: ✗ worse than the web
  stress | typing (frames) | web 8.7 / 8.7 (0) | native 7.0 / 9.1 (0) | was: ✓ tie at the display's refresh → now: ✗ worse than the web
  rows changed: 7
```
