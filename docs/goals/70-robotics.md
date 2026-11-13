# Goal 70 M2: goal 68's robotics compute, the app's way vs the engine's

Written by docs/goals/70-check.py M2 from its own run (tests/bench_robotics.mojo, docs/goals/70/similarity.py; medians of 5). The app's similarity is numpy float32 as mojoui/plugin_py.py's similar(); answers are compared with float64 (the engine has no float32).

| path | app ms | engine ms | engine / app | answers | decision |
|---|---:|---:|---:|---|---|
| asof | 1.5 | 20.7 | 13.5× | equal | stays |
| asof_1m | 8.2 | 285.4 | 35.0× | equal | stays |
| stops | 1.2 | 98.5 | 80.4× | equal | stays |
| learn_reads | 7.9 | 16.5 | 2.1× | equal | stays |
| similarity_all | 11.0 | 60.9 | 5.5× | equal | stays |
| similarity_top10 | 8.9 | 65.5 | 7.3× | equal | stays |
