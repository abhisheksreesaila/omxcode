# Goal 68's fleet (build/g68/fleet: tests/test_fleet over build/bags, scripts/fetch_bags.py): the story's questions, its links, a pivot and charts
table | runs | build/g68/fleet/runs.csv
table | moments | build/g68/fleet/moments.csv
table | stops | build/g68/fleet/stops.csv
link | runs.run = moments.run
link | runs.run = stops.run
sql | g68_stood_still | SELECT run, robot, stopped_s, stops, duration_s FROM runs ORDER BY stopped_s DESC
sql | g68_person_near | SELECT run, robot, t, person_m, speed FROM moments WHERE person_m < 1.5 ORDER BY person_m, run, t
sql | g68_speed_by_robot | SELECT robot, COUNT(*) AS moments, AVG(speed) AS speed FROM moments WHERE speed > 0.05 GROUP BY robot ORDER BY speed DESC
sql | g68_stops_by_run | SELECT run, COUNT(*) AS half_seconds, MIN(person_m) AS nearest_person FROM stops GROUP BY run ORDER BY half_seconds DESC, run
sql | g68_join_linked | SELECT runs.run, runs.distance_m, COUNT(*) AS n, MAX(stops.stopped_for) AS longest FROM runs JOIN LINKED GROUP BY runs.run, runs.distance_m ORDER BY runs.run
sql | g68_join_moments | SELECT runs.robot, COUNT(DISTINCT moments.run) AS runs, SUM(moments.speed) AS speed FROM runs JOIN moments ON runs.run = moments.run GROUP BY runs.robot ORDER BY runs.robot
pivot | g68_pivot_stops | stops | stopped_for | run | robot
chart | g68_chart_speed | moments | speed | run | average
chart | g68_chart_median_speed | moments | speed | run | median
chart | g68_chart_person | moments | person_m | run | sum
