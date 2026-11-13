# Goal 70 M1: the app's query paths, omxcore 834ef9a vs a9a3c37

Same machine, same run: 2 interleaved rounds of 5 runs each per build (median of 10); load average 5.2–9.4 on 24 cores (other sessions), so ratios within ~10 % of 1 are noise. 47 answers compared byte for byte across the three builds: 0 differ, 0 are refusals. Made by `docs/goals/70/bench_m1.py`; the paths are tests/bench_engine_paths.mojo's (implied_sql + query_table, sheetpage.compute).

Builds: **main** = 834ef9a, every sheet as a Frame (main today); **old+sheet** = 834ef9a with this branch's add_sheet (an untouched sheet as a plain table, D-7006); **new** = a9a3c37 with add_sheet (this branch). **Engine** = old+sheet / new (the engine's change alone); **branch** = main / new (what a user gets). Above 1: faster.

| data | step | main ms | old+sheet ms | new ms | engine | branch |
|---|---|---:|---:|---:|---:|---:|
| fleet68 | g68_stood_still | 0.08 | 0.08 | 0.07 | 1.15× | 1.11× |
| fleet68 | g68_person_near | 0.64 | 0.66 | 0.61 | 1.08× | 1.06× |
| fleet68 | g68_speed_by_robot | 0.64 | 0.64 | 0.60 | 1.08× | 1.08× |
| fleet68 | g68_stops_by_run | 0.16 | 0.14 | 0.13 | 1.10× | 1.23× |
| fleet68 | g68_join_linked | 0.28 | 0.23 | 0.23 | 0.98× | 1.22× |
| fleet68 | g68_join_moments | 0.74 | 0.69 | 0.66 | 1.05× | 1.13× |
| fleet68 | g68_pivot_stops | 0.04 | 0.04 | 0.04 | 0.92× | 0.94× |
| fleet68 | g68_chart_speed | 0.03 | 0.03 | 0.03 | 0.98× | 1.00× |
| fleet68 | g68_chart_median_speed | 0.10 | 0.11 | 0.08 | 1.46× | 1.27× |
| fleet68 | g68_chart_person | 0.03 | 0.03 | 0.03 | 1.02× | 1.05× |
| fleet47 | g47_q1_regrasped_failures | 22.81 | 27.50 | 85.59 | 0.32× | 0.27× |
| fleet47 | g47_q2_near_limit | 15.07 | 10.90 | 26.08 | 0.42× | 0.58× |
| fleet47 | g47_q3_picked | 0.26 | 0.25 | 0.24 | 1.06× | 1.10× |
| fleet47 | g47_success_by_lab | 0.51 | 0.54 | 0.40 | 1.35× | 1.27× |
| fleet47 | g47_distinct_robots | 2.46 | 2.43 | 2.20 | 1.11× | 1.12× |
| fleet47 | g47_telemetry_by_event | 16.08 | 16.05 | 14.39 | 1.12× | 1.12× |
| fleet47 | g47_join_lab_speed | 250.95 | 78.22 | 75.40 | 1.04× | 3.33× |
| fleet47 | g47_chart_success_by_lab | 0.72 | 0.74 | 0.56 | 1.31× | 1.29× |
| fleet47 | g47_chart_success_by_verb | 0.70 | 0.68 | 0.55 | 1.25× | 1.28× |
| fleet47 | g47_chart_median_duration | 1.59 | 1.57 | 1.48 | 1.06× | 1.07× |
| fleet47 | g47_pivot_lab_outcome | 1.84 | 1.86 | 1.50 | 1.24× | 1.23× |
| fleet47 | g47_chart_telemetry_speed | 20.39 | 19.64 | 16.72 | 1.17× | 1.22× |
| tpch | tpch_q01 | 15.05 | 14.89 | 14.28 | 1.04× | 1.05× |
| tpch | tpch_q02 | 29.97 | 15.65 | 13.72 | 1.14× | 2.18× |
| tpch | tpch_q03 | 48.46 | 32.40 | 26.92 | 1.20× | 1.80× |
| tpch | tpch_q04 | 25.87 | 27.38 | 12.83 | 2.13× | 2.02× |
| tpch | tpch_q05 | 98.58 | 36.52 | 22.35 | 1.63× | 4.41× |
| tpch | tpch_q06 | 10.95 | 11.55 | 5.22 | 2.21× | 2.10× |
| tpch | tpch_q07 | 72.22 | 68.70 | 17.43 | 3.94× | 4.14× |
| tpch | tpch_q08 | 86.88 | 28.42 | 31.42 | 0.90× | 2.77× |
| tpch | tpch_q09 | 133.86 | 54.47 | 53.97 | 1.01× | 2.48× |
| tpch | tpch_q10 | 154.74 | 78.18 | 18.97 | 4.12× | 8.16× |
| tpch | tpch_q11 | 20.45 | 6.94 | 5.77 | 1.20× | 3.54× |
| tpch | tpch_q12 | 34.41 | 31.08 | 21.59 | 1.44× | 1.59× |
| tpch | tpch_q13 | 98.88 | 96.32 | 32.91 | 2.93× | 3.00× |
| tpch | tpch_q14 | 10.90 | 12.07 | 7.03 | 1.72× | 1.55× |
| tpch | tpch_q15 | 10.03 | 6.77 | 5.25 | 1.29× | 1.91× |
| tpch | tpch_q16 | 24.34 | 22.56 | 23.62 | 0.96× | 1.03× |
| tpch | tpch_q17 | 68.94 | 28.91 | 11.49 | 2.52× | 6.00× |
| tpch | tpch_q18 | 365.19 | 304.21 | 45.03 | 6.76× | 8.11× |
| tpch | tpch_q19 | 21.80 | 22.89 | 13.80 | 1.66× | 1.58× |
| tpch | tpch_q20 | 242.14 | 51.79 | 15.33 | 3.38× | 15.79× |
| tpch | tpch_q21 | 251.50 | 272.81 | 47.86 | 5.70× | 5.25× |
| tpch | tpch_q22 | 84.77 | 180.27 | 9.73 | 18.52× | 8.71× |
| tpch | tpch_pivot_flag_status | 3.78 | 3.92 | 3.78 | 1.04× | 1.00× |
| tpch | tpch_chart_sum_shipmode | 1.92 | 2.00 | 1.92 | 1.04× | 1.00× |
| tpch | tpch_chart_median_shipmode | 37.22 | 88.36 | 37.15 | 2.38× | 1.00× |

Opening the tables (read_table, not timed above; main → new): fleet68/runs 184 → 159 ms; fleet68/moments 6 → 6 ms; fleet68/stops 0 → 0 ms; fleet47/fleet 317 → 355 ms; fleet47/telemetry 882 → 1029 ms; tpch/lineitem 3810 → 4218 ms; tpch/orders 883 → 904 ms; tpch/customer 202 → 202 ms; tpch/part 124 → 124 ms; tpch/partsupp 551 → 565 ms; tpch/supplier 11 → 11 ms; tpch/nation 0 → 0 ms; tpch/region 0 → 0 ms
