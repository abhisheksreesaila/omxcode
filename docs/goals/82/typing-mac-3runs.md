# Goal 82 integration: Mac typing, before vs after the CoreText cluster fix (middle of 3 alternated runs, ms)

- 600: key to paint p95/max 1.4/1.4 → 1.6/1.6; key to frame begun 0.8/0.8 → 0.8/0.8; frame gaps p95/max 2.3/7.3 → 2.3/7.1
- 600 not warmed: key to paint p95/max 1.8/1.8 → 1.4/1.4; key to frame begun 0.7/0.7 → 0.6/0.6; frame gaps p95/max 2.5/7.5 → 2.5/7.2
- stress: key to paint p95/max 1.4/1.4 → 1.8/1.8; key to frame begun 0.7/0.7 → 0.9/0.9; frame gaps p95/max 2.5/6.7 → 2.6/7.5
- stress not warmed: key to paint p95/max 1.5/1.5 → 1.4/1.4; key to frame begun 0.7/0.7 → 0.6/0.6; frame gaps p95/max 2.2/7.0 → 2.3/7.4
- page 20,000 chars: key to paint p95/max 1.9/1.9 → 2.0/2.0; key to frame begun 1.0/1.0 → 1.0/1.0; frame gaps p95/max 3.9/11.5 → 3.9/10.5

Worse by more than 3 %: 600 lat_p95 1.40 → 1.60 (+14.3 %); 600 lat_max 1.40 → 1.60 (+14.3 %); stress lat_p95 1.40 → 1.80 (+28.6 %); stress lat_max 1.40 → 1.80 (+28.6 %); stress lat_code_p95 0.70 → 0.90 (+28.6 %); stress lat_code_max 0.70 → 0.90 (+28.6 %); stress gap_p95 2.50 → 2.60 (+4.0 %); stress gap_max 6.70 → 7.50 (+11.9 %); stress not warmed gap_p95 2.20 → 2.30 (+4.5 %); stress not warmed gap_max 7.00 → 7.40 (+5.7 %); page 20,000 chars lat_p95 1.90 → 2.00 (+5.3 %); page 20,000 chars lat_max 1.90 → 2.00 (+5.3 %)
