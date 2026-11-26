# The late redo after step 2b (stress note, redo latency max over 18.3 ms at 60 Hz): A/B runs

build/merge/ab_paced.py: goal 79's own paced stress run (79-check.py's PACED_RACE, env and testscreen), one process per run, modes interleaved, on an idle machine (gpu-free yes). Late = lat_max > 18.33 ms (one 60 Hz refresh + 10 %, D-8097). Modes: base = pnote built at b42cd6d4 (step 2); default = step 2b (dbf5349b); none/nocss/nopaint = dbf5349b with a temporary switch (never committed): no overlay root, overlay without the root's CSS class, overlay and class without the window paintable; fixed = the class only while a morph settles (D-8220).

| build | late runs |
|---|---|
| base (step 2) | 3 of 21 |
| default (step 2b, before the fix) | 8 of 13 (two full M6 races included) |
| nopaint (class kept) | 1 of 2 |
| nocss | 1 of 6 |
| none | 0 of 2 |
| fixed | 5 of 16 |

Raw lines:
```
0 default  redo: lat_p95 16.8 lat_max 18.7 work max 4.1 gap_max 16.7
0 default  undo: lat_p95 16.8 lat_max 16.8 work max 5.9 gap_max 16.7
0 none     redo: lat_p95 16.8 lat_max 16.8 work max 3.8 gap_max 16.7
0 none     undo: lat_p95 16.8 lat_max 16.8 work max 5.1 gap_max 16.7
0 nocss    redo: lat_p95 16.8 lat_max 16.8 work max 3.9 gap_max 16.7
0 nocss    undo: lat_p95 16.8 lat_max 16.8 work max 5.1 gap_max 16.7
0 nopaint  redo: lat_p95 16.8 lat_max 18.7 work max 3.8 gap_max 16.7
0 nopaint  undo: lat_p95 16.7 lat_max 16.8 work max 5.8 gap_max 16.7
1 default  redo: lat_p95 16.8 lat_max 16.8 work max 4.4 gap_max 16.7
1 default  undo: lat_p95 16.8 lat_max 16.8 work max 6.0 gap_max 16.8
1 none     redo: lat_p95 16.8 lat_max 17.0 work max 4.0 gap_max 16.8
1 none     undo: lat_p95 16.8 lat_max 16.8 work max 5.9 gap_max 16.7
1 nocss    redo: lat_p95 16.7 lat_max 16.7 work max 4.2 gap_max 16.7
1 nocss    undo: lat_p95 16.8 lat_max 16.8 work max 5.7 gap_max 16.8
1 nopaint  redo: lat_p95 16.8 lat_max 16.8 work max 4.0 gap_max 16.7
1 nopaint  undo: lat_p95 18.8 lat_max 22.9 work max 17.3 gap_max 17.4
0 default  redo: lat_p95 17.0 lat_max 17.6 work max 4.0 gap_max 16.9
0 default  undo: lat_p95 16.8 lat_max 16.8 work max 5.6 gap_max 16.8
0 nocss    redo: lat_p95 16.9 lat_max 16.9 work max 3.9 gap_max 17.0
0 nocss    undo: lat_p95 16.9 lat_max 16.9 work max 1.9 gap_max 16.9
1 default  redo: lat_p95 16.9 lat_max 16.9 work max 4.1 gap_max 17.0
1 default  undo: lat_p95 16.8 lat_max 16.9 work max 1.9 gap_max 16.9
1 nocss    redo: lat_p95 16.9 lat_max 16.9 work max 3.8 gap_max 16.9
1 nocss    undo: lat_p95 16.9 lat_max 16.9 work max 2.0 gap_max 16.9
2 default  redo: lat_p95 17.1 lat_max 18.9 work max 4.8 gap_max 17.0
2 default  undo: lat_p95 16.8 lat_max 16.9 work max 2.1 gap_max 16.9
2 nocss    redo: lat_p95 16.9 lat_max 19.1 work max 4.1 gap_max 16.9
2 nocss    undo: lat_p95 16.9 lat_max 17.0 work max 2.0 gap_max 17.0
3 default  redo: lat_p95 16.8 lat_max 17.0 work max 4.0 gap_max 17.0
3 default  undo: lat_p95 16.9 lat_max 16.9 work max 3.1 gap_max 16.9
3 nocss    redo: lat_p95 16.9 lat_max 16.9 work max 3.8 gap_max 16.9
3 nocss    undo: lat_p95 16.9 lat_max 16.9 work max 2.2 gap_max 16.9
0 base     redo: lat_p95 16.8 lat_max 16.8 work max 4.1 gap_max 16.8
0 default  redo: lat_p95 16.9 lat_max 18.6 work max 3.8 gap_max 17.0
1 base     redo: lat_p95 16.9 lat_max 16.9 work max 3.8 gap_max 17.0
1 default  redo: lat_p95 16.9 lat_max 19.0 work max 4.0 gap_max 16.9
2 base     redo: lat_p95 16.7 lat_max 16.7 work max 4.2 gap_max 16.7
2 default  redo: lat_p95 16.8 lat_max 18.8 work max 4.2 gap_max 16.8
3 base     redo: lat_p95 16.9 lat_max 18.8 work max 3.9 gap_max 17.0
3 default  redo: lat_p95 16.9 lat_max 16.9 work max 3.8 gap_max 16.9
4 base     redo: lat_p95 17.0 lat_max 17.0 work max 4.0 gap_max 17.0
4 default  redo: lat_p95 17.2 lat_max 19.0 work max 4.1 gap_max 17.0
0 base     redo: lat_p95 16.9 lat_max 17.0 work max 4.4 gap_max 17.0
0 default  redo: lat_p95 16.8 lat_max 16.8 work max 4.2 gap_max 16.8
1 base     redo: lat_p95 17.2 lat_max 17.4 work max 3.8 gap_max 17.2
1 default  redo: lat_p95 16.8 lat_max 16.9 work max 4.0 gap_max 17.0
2 base     redo: lat_p95 16.8 lat_max 16.8 work max 4.0 gap_max 16.8
2 default  redo: lat_p95 16.9 lat_max 18.9 work max 3.9 gap_max 16.8
3 base     redo: lat_p95 16.8 lat_max 16.8 work max 3.8 gap_max 16.8
3 default  redo: lat_p95 16.8 lat_max 16.8 work max 4.3 gap_max 16.9
4 base     redo: lat_p95 16.9 lat_max 16.9 work max 4.2 gap_max 17.0
4 default  redo: lat_p95 16.8 lat_max 16.8 work max 3.9 gap_max 16.8
5 base     redo: lat_p95 16.9 lat_max 16.9 work max 3.9 gap_max 17.0
5 default  redo: lat_p95 16.8 lat_max 18.9 work max 4.2 gap_max 16.9
0 base     redo: lat_p95 16.9 lat_max 17.4 work max 4.5 gap_max 17.2
0 default  redo: lat_p95 16.9 lat_max 19.0 work max 4.8 gap_max 19.0
1 base     redo: lat_p95 16.9 lat_max 16.9 work max 4.6 gap_max 16.9
1 default  redo: lat_p95 17.0 lat_max 18.9 work max 4.4 gap_max 16.9
2 base     redo: lat_p95 16.9 lat_max 17.0 work max 3.9 gap_max 16.9
2 default  redo: lat_p95 16.9 lat_max 16.9 work max 4.3 gap_max 16.9
3 base     redo: lat_p95 16.8 lat_max 16.9 work max 4.2 gap_max 16.9
3 default  redo: lat_p95 16.9 lat_max 17.0 work max 4.6 gap_max 17.1
4 base     redo: lat_p95 17.1 lat_max 18.8 work max 4.4 gap_max 17.1
4 default  redo: lat_p95 16.9 lat_max 16.9 work max 3.9 gap_max 16.9
5 base     redo: lat_p95 16.8 lat_max 16.8 work max 3.9 gap_max 17.0
5 default  redo: lat_p95 16.8 lat_max 16.8 work max 3.9 gap_max 16.9
6 base     redo: lat_p95 16.9 lat_max 18.8 work max 3.8 gap_max 16.9
6 default  redo: lat_p95 16.7 lat_max 16.7 work max 4.2 gap_max 16.7
7 base     redo: lat_p95 16.9 lat_max 16.9 work max 3.8 gap_max 17.0
7 default  redo: lat_p95 16.9 lat_max 16.9 work max 4.2 gap_max 16.9
8 base     redo: lat_p95 16.9 lat_max 17.2 work max 3.8 gap_max 17.0
8 default  redo: lat_p95 16.8 lat_max 19.3 work max 4.4 gap_max 16.9
9 base     redo: lat_p95 16.9 lat_max 17.4 work max 3.9 gap_max 17.3
9 default  redo: lat_p95 16.7 lat_max 16.8 work max 4.2 gap_max 16.8
```
