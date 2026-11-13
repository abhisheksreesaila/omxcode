# Goal 70 M1: the app's query paths, omxcore 834ef9a vs a9a3c37

Same machine, same run: 3 interleaved rounds of 5 runs each per build (median of 15); load average 3.7–5.7 on 24 cores (other sessions). Noise seen: identical code (charts and pivots, main vs old+sheet: they don't touch the catalog) landed up to 1.23× apart, so a single step's ratio within that is not a finding. 47 answers compared byte for byte across the three builds: 0 differ, 0 are refusals. Made by `docs/goals/70/bench_m1.py`; the paths are tests/bench_engine_paths.mojo's (implied_sql + query_table, sheetpage.compute).

Builds: **main** = 834ef9a, every sheet as a Frame (main today); **old+sheet** = 834ef9a with this branch's add_sheet (an untouched sheet as a plain table, D-7006); **new** = a9a3c37 with add_sheet (this branch). **Engine** = old+sheet / new (the engine's change alone); **branch** = main / new (what a user gets). Above 1: faster.

| data | step | main ms | old+sheet ms | new ms | engine | branch |
|---|---|---:|---:|---:|---:|---:|
| fleet68 | g68_stood_still | 0.08 | 0.08 | 0.08 | 0.96× | 0.94× |
| fleet68 | g68_person_near | 0.64 | 0.64 | 0.64 | 1.00× | 1.00× |
| fleet68 | g68_speed_by_robot | 0.62 | 0.63 | 0.64 | 0.99× | 0.98× |
| fleet68 | g68_stops_by_run | 0.14 | 0.14 | 0.15 | 0.92× | 0.95× |
| fleet68 | g68_join_linked | 0.26 | 0.22 | 0.24 | 0.93× | 1.08× |
| fleet68 | g68_join_moments | 0.74 | 0.64 | 0.70 | 0.91× | 1.05× |
| fleet68 | g68_pivot_stops | 0.04 | 0.04 | 0.04 | 0.90× | 0.90× |
| fleet68 | g68_chart_speed | 0.03 | 0.03 | 0.03 | 1.00× | 0.97× |
| fleet68 | g68_chart_median_speed | 0.10 | 0.08 | 0.11 | 0.78× | 0.95× |
| fleet68 | g68_chart_person | 0.03 | 0.03 | 0.03 | 0.97× | 0.94× |
| fleet47 | g47_q1_regrasped_failures | 24.20 | 29.49 | 83.71 | 0.35× | 0.29× |
| fleet47 | g47_q2_near_limit | 17.62 | 11.09 | 25.98 | 0.43× | 0.68× |
| fleet47 | g47_q3_picked | 0.26 | 0.26 | 0.25 | 1.00× | 1.00× |
| fleet47 | g47_success_by_lab | 0.50 | 0.51 | 0.46 | 1.10× | 1.09× |
| fleet47 | g47_distinct_robots | 2.40 | 2.56 | 2.37 | 1.08× | 1.01× |
| fleet47 | g47_telemetry_by_event | 15.47 | 16.05 | 14.57 | 1.10× | 1.06× |
| fleet47 | g47_join_lab_speed | 253.71 | 75.45 | 74.58 | 1.01× | 3.40× |
| fleet47 | g47_chart_success_by_lab | 0.72 | 0.72 | 0.57 | 1.26× | 1.26× |
| fleet47 | g47_chart_success_by_verb | 0.70 | 0.69 | 0.54 | 1.27× | 1.30× |
| fleet47 | g47_chart_median_duration | 1.70 | 1.65 | 1.42 | 1.17× | 1.20× |
| fleet47 | g47_pivot_lab_outcome | 1.81 | 1.79 | 1.48 | 1.21× | 1.22× |
| fleet47 | g47_chart_telemetry_speed | 19.19 | 19.65 | 16.61 | 1.18× | 1.16× |
| tpch | tpch_q01 | 15.64 | 14.46 | 14.18 | 1.02× | 1.10× |
| tpch | tpch_q02 | 30.04 | 15.33 | 12.69 | 1.21× | 2.37× |
| tpch | tpch_q03 | 52.17 | 33.06 | 26.55 | 1.25× | 1.97× |
| tpch | tpch_q04 | 26.97 | 27.50 | 13.26 | 2.07× | 2.03× |
| tpch | tpch_q05 | 93.79 | 37.47 | 22.40 | 1.67× | 4.19× |
| tpch | tpch_q06 | 12.02 | 11.42 | 5.63 | 2.03× | 2.13× |
| tpch | tpch_q07 | 74.25 | 70.24 | 17.87 | 3.93× | 4.16× |
| tpch | tpch_q08 | 87.04 | 27.24 | 29.68 | 0.92× | 2.93× |
| tpch | tpch_q09 | 135.82 | 53.70 | 51.23 | 1.05× | 2.65× |
| tpch | tpch_q10 | 145.06 | 79.62 | 19.01 | 4.19× | 7.63× |
| tpch | tpch_q11 | 19.54 | 7.35 | 5.60 | 1.31× | 3.49× |
| tpch | tpch_q12 | 32.06 | 31.62 | 20.45 | 1.55× | 1.57× |
| tpch | tpch_q13 | 97.03 | 97.72 | 34.61 | 2.82× | 2.80× |
| tpch | tpch_q14 | 10.77 | 12.04 | 6.97 | 1.73× | 1.54× |
| tpch | tpch_q15 | 10.03 | 6.68 | 5.58 | 1.20× | 1.80× |
| tpch | tpch_q16 | 25.31 | 22.39 | 22.50 | 1.00× | 1.13× |
| tpch | tpch_q17 | 66.78 | 29.59 | 11.56 | 2.56× | 5.78× |
| tpch | tpch_q18 | 362.91 | 320.59 | 46.24 | 6.93× | 7.85× |
| tpch | tpch_q19 | 20.34 | 23.04 | 13.62 | 1.69× | 1.49× |
| tpch | tpch_q20 | 232.00 | 54.06 | 15.58 | 3.47× | 14.89× |
| tpch | tpch_q21 | 251.95 | 262.34 | 47.95 | 5.47× | 5.25× |
| tpch | tpch_q22 | 84.82 | 113.89 | 8.43 | 13.51× | 10.06× |
| tpch | tpch_pivot_flag_status | 3.77 | 3.75 | 3.79 | 0.99× | 0.99× |
| tpch | tpch_chart_sum_shipmode | 1.91 | 1.91 | 1.93 | 0.99× | 0.99× |
| tpch | tpch_chart_median_shipmode | 37.33 | 37.41 | 37.57 | 1.00× | 0.99× |

Opening the tables (read_table, not timed above; main → new): fleet68/runs 159 → 158 ms; fleet68/moments 6 → 6 ms; fleet68/stops 0 → 0 ms; fleet47/fleet 315 → 318 ms; fleet47/telemetry 873 → 885 ms; tpch/lineitem 3457 → 3481 ms; tpch/orders 903 → 887 ms; tpch/customer 211 → 205 ms; tpch/part 134 → 125 ms; tpch/partsupp 590 → 558 ms; tpch/supplier 11 → 11 ms; tpch/nation 0 → 0 ms; tpch/region 0 → 0 ms
