# Goal 70 M2: goal 68's robotics compute, the app's way vs the engine's

Written by docs/goals/70-check.py M2 from its own run (tests/bench_robotics.mojo, docs/goals/70/similarity.py; medians of 5). The app's similarity is numpy float32 as mojoui/plugin_py.py's similar(); answers are compared with float64 (the engine has no float32).

| path | app ms | engine ms | engine / app | answers | decision |
|---|---:|---:|---:|---|---|
| asof | 1.6 | 22.2 | 13.8× | equal | stays |
| asof_1m | 9.2 | 305.1 | 33.2× | equal | stays |
| stops | 1.3 | 94.9 | 75.6× | equal | stays |
| learn_reads | 7.9 | 16.3 | 2.1× | equal | stays |
| similarity_all | 15.5 | 62.7 | 4.0× | equal | stays |
| similarity_top10 | 10.0 | 67.4 | 6.8× | equal | stays |
