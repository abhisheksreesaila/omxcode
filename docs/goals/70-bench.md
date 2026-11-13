# Goal 70 M1: the app's query paths, omxcore 834ef9a vs a9a3c37

Same machine, same run: 3 interleaved rounds of 5 runs each per build (median of 15); load average 4.4–9.0 on 24 cores (other sessions). Noise seen: identical code (charts and pivots, main vs old+sheet: they don't touch the catalog; steps of 1 ms or more) landed up to 1.03× apart, so a ratio within that is not a finding (sub-millisecond steps jitter more). 47 answers compared byte for byte across the three builds: 0 differ, 0 are refusals. Made by `docs/goals/70/bench_m1.py`; the paths are tests/bench_engine_paths.mojo's (implied_sql + query_table, sheetpage.compute).

Builds: **main** = 834ef9a, every sheet as a Frame (main today); **old+sheet** = 834ef9a with this branch's add_sheet (an untouched sheet as a plain table, D-7006); **new** = a9a3c37 with add_sheet (this branch). **Engine** = old+sheet / new (the engine's change alone); **branch** = main / new (what a user gets). Above 1: faster.

| data | step | main ms | old+sheet ms | new ms | engine | branch |
|---|---|---:|---:|---:|---:|---:|
| fleet68 | g68_stood_still | 0.08 | 0.08 | 0.08 | 0.95× | 0.96× |
| fleet68 | g68_person_near | 0.63 | 0.64 | 0.65 | 0.98× | 0.98× |
| fleet68 | g68_speed_by_robot | 0.63 | 0.63 | 0.64 | 0.98× | 0.98× |
| fleet68 | g68_stops_by_run | 0.14 | 0.14 | 0.15 | 0.93× | 0.92× |
| fleet68 | g68_join_linked | 0.27 | 0.22 | 0.25 | 0.90× | 1.10× |
| fleet68 | g68_join_moments | 0.70 | 0.65 | 0.70 | 0.93× | 1.00× |
| fleet68 | g68_pivot_stops | 0.04 | 0.04 | 0.04 | 0.90× | 0.88× |
| fleet68 | g68_chart_speed | 0.03 | 0.03 | 0.03 | 0.97× | 0.97× |
| fleet68 | g68_chart_median_speed | 0.08 | 0.08 | 0.11 | 0.72× | 0.73× |
| fleet68 | g68_chart_person | 0.03 | 0.03 | 0.04 | 0.89× | 0.89× |
| fleet47 | g47_q1_regrasped_failures | 24.11 | 29.35 | 85.25 | 0.34× | 0.28× |
| fleet47 | g47_q2_near_limit | 16.14 | 11.13 | 27.09 | 0.41× | 0.60× |
| fleet47 | g47_q3_picked | 0.26 | 0.27 | 0.26 | 1.04× | 1.02× |
| fleet47 | g47_success_by_lab | 0.52 | 0.53 | 0.47 | 1.13× | 1.10× |
| fleet47 | g47_distinct_robots | 2.50 | 2.43 | 2.35 | 1.04× | 1.07× |
| fleet47 | g47_telemetry_by_event | 15.41 | 15.94 | 15.00 | 1.06× | 1.03× |
| fleet47 | g47_join_lab_speed | 260.24 | 78.16 | 74.56 | 1.05× | 3.49× |
| fleet47 | g47_chart_success_by_lab | 0.73 | 0.74 | 0.55 | 1.35× | 1.34× |
| fleet47 | g47_chart_success_by_verb | 0.70 | 0.69 | 0.53 | 1.30× | 1.33× |
| fleet47 | g47_chart_median_duration | 1.68 | 1.66 | 1.38 | 1.20× | 1.21× |
| fleet47 | g47_pivot_lab_outcome | 1.86 | 1.80 | 1.44 | 1.26× | 1.30× |
| fleet47 | g47_chart_telemetry_speed | 19.72 | 19.40 | 16.96 | 1.14× | 1.16× |
| tpch | tpch_q01 | 15.31 | 14.95 | 14.64 | 1.02× | 1.05× |
| tpch | tpch_q02 | 31.29 | 15.76 | 12.47 | 1.26× | 2.51× |
| tpch | tpch_q03 | 50.70 | 34.23 | 26.29 | 1.30× | 1.93× |
| tpch | tpch_q04 | 26.09 | 27.77 | 13.27 | 2.09× | 1.97× |
| tpch | tpch_q05 | 100.04 | 38.80 | 21.73 | 1.79× | 4.60× |
| tpch | tpch_q06 | 11.21 | 11.44 | 5.16 | 2.22× | 2.17× |
| tpch | tpch_q07 | 78.33 | 71.92 | 17.05 | 4.22× | 4.59× |
| tpch | tpch_q08 | 85.37 | 28.63 | 28.43 | 1.01× | 3.00× |
| tpch | tpch_q09 | 145.17 | 55.58 | 49.85 | 1.12× | 2.91× |
| tpch | tpch_q10 | 151.37 | 79.47 | 18.38 | 4.32× | 8.24× |
| tpch | tpch_q11 | 21.17 | 7.63 | 5.58 | 1.37× | 3.79× |
| tpch | tpch_q12 | 34.61 | 34.20 | 20.18 | 1.69× | 1.71× |
| tpch | tpch_q13 | 96.12 | 103.67 | 34.94 | 2.97× | 2.75× |
| tpch | tpch_q14 | 10.93 | 13.29 | 7.01 | 1.90× | 1.56× |
| tpch | tpch_q15 | 9.77 | 7.32 | 5.64 | 1.30× | 1.73× |
| tpch | tpch_q16 | 25.66 | 23.70 | 22.67 | 1.05× | 1.13× |
| tpch | tpch_q17 | 67.85 | 30.83 | 12.01 | 2.57× | 5.65× |
| tpch | tpch_q18 | 376.84 | 321.56 | 46.65 | 6.89× | 8.08× |
| tpch | tpch_q19 | 21.90 | 24.16 | 13.72 | 1.76× | 1.60× |
| tpch | tpch_q20 | 257.30 | 54.38 | 15.54 | 3.50× | 16.55× |
| tpch | tpch_q21 | 267.57 | 265.21 | 47.56 | 5.58× | 5.63× |
| tpch | tpch_q22 | 88.61 | 115.48 | 9.46 | 12.21× | 9.37× |
| tpch | tpch_pivot_flag_status | 3.77 | 3.77 | 3.78 | 1.00× | 1.00× |
| tpch | tpch_chart_sum_shipmode | 1.92 | 1.92 | 1.93 | 0.99× | 0.99× |
| tpch | tpch_chart_median_shipmode | 38.58 | 37.58 | 38.70 | 0.97× | 1.00× |

Opening the tables (read_table, not timed above; main → new): fleet68/runs 165 → 163 ms; fleet68/moments 6 → 7 ms; fleet68/stops 0 → 0 ms; fleet47/fleet 341 → 336 ms; fleet47/telemetry 869 → 861 ms; tpch/lineitem 4014 → 4060 ms; tpch/orders 897 → 860 ms; tpch/customer 201 → 202 ms; tpch/part 124 → 123 ms; tpch/partsupp 552 → 561 ms; tpch/supplier 10 → 10 ms; tpch/nation 0 → 0 ms; tpch/region 0 → 0 ms
