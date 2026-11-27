# Goal 82 integration: Mac typing, before vs after the CoreText cluster fix (median of 7 alternated runs a side, ms)

- 600: key to paint p95/max 1.5/1.5 → 1.3/1.3; key to frame begun 0.7/0.7 → 0.7/0.7; frame gaps p95/max 2.3/7.3 → 2.3/6.9
- 600 not warmed: key to paint p95/max 1.4/1.4 → 1.5/1.5; key to frame begun 0.7/0.7 → 0.6/0.6; frame gaps p95/max 2.2/8.1 → 2.5/7.2
- stress: key to paint p95/max 1.5/1.5 → 1.6/1.6; key to frame begun 0.7/0.7 → 0.8/0.8; frame gaps p95/max 2.5/7.0 → 2.6/7.5
- stress not warmed: key to paint p95/max 1.6/1.6 → 1.5/1.5; key to frame begun 0.7/0.7 → 0.7/0.7; frame gaps p95/max 2.2/7.1 → 2.3/7.4
- page 20,000 chars: key to paint p95/max 1.9/1.9 → 1.8/1.8; key to frame begun 0.9/0.9 → 0.9/0.9; frame gaps p95/max 4.1/11.2 → 3.9/10.5

Worse by more than 3 %: 600 not warmed lat_p95 1.40 → 1.50 (+7.1 %); 600 not warmed lat_max 1.40 → 1.50 (+7.1 %); 600 not warmed gap_p95 2.20 → 2.50 (+13.6 %); stress lat_p95 1.50 → 1.60 (+6.7 %); stress lat_max 1.50 → 1.60 (+6.7 %); stress lat_code_p95 0.70 → 0.80 (+14.3 %); stress lat_code_max 0.70 → 0.80 (+14.3 %); stress gap_p95 2.50 → 2.60 (+4.0 %); stress gap_max 7.00 → 7.50 (+7.1 %); stress not warmed gap_p95 2.20 → 2.30 (+4.5 %); stress not warmed gap_max 7.10 → 7.40 (+4.2 %)
