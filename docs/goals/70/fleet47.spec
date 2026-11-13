# Goal 47's DROID fleet (build/g47/full: scripts/robot_data.py over ~/data/robot-scout): 63,345 episodes and 16.8M telemetry rows; the story's questions (scripts/scenario.py), its chart and pivots
table | fleet | build/g47/full/fleet.csv
table | telemetry | build/g47/full/telemetry.parquet
link | fleet.episode = telemetry.episode
sql | g47_q1_regrasped_failures | SELECT fleet.episode AS episode, fleet.lab AS lab, fleet.task AS task, fleet.clip AS clip, fleet.source AS source, COUNT(*) AS closes FROM fleet JOIN LINKED WHERE fleet.success = 0 AND telemetry.gripper_event = 'close' GROUP BY fleet.episode, fleet.lab, fleet.task, fleet.clip, fleet.source HAVING COUNT(*) >= 2 ORDER BY closes DESC, episode
sql | g47_q2_near_limit | SELECT fleet.episode AS episode, fleet.lab AS lab, fleet.outcome AS outcome, MAX(telemetry.speed) AS peak FROM fleet JOIN LINKED WHERE telemetry.speed > 1.5225 GROUP BY fleet.episode, fleet.lab, fleet.outcome ORDER BY peak DESC, episode
sql | g47_q3_picked | SELECT fleet.episode AS episode, fleet.lab AS lab, fleet.date AS date, fleet.task AS task, fleet.duration_s AS duration_s, fleet.grasps AS grasps, fleet.peak_speed AS peak_speed FROM fleet WHERE fleet.episode IN ('F00118', 'F00119', 'F00124') ORDER BY episode
sql | g47_success_by_lab | SELECT lab, COUNT(*) AS episodes, AVG(success_pct) AS success FROM fleet GROUP BY lab ORDER BY success DESC, lab
sql | g47_distinct_robots | SELECT lab, COUNT(DISTINCT robot) AS robots, COUNT(DISTINCT verb) AS verbs FROM fleet GROUP BY lab ORDER BY lab
sql | g47_telemetry_by_event | SELECT gripper_event, COUNT(*) AS n, AVG(speed) AS speed, MAX(track_err) AS worst FROM telemetry GROUP BY gripper_event ORDER BY gripper_event
sql | g47_join_lab_speed | SELECT fleet.lab, COUNT(*) AS frames, AVG(telemetry.speed) AS speed FROM fleet JOIN telemetry ON fleet.episode = telemetry.episode WHERE fleet.success = 0 GROUP BY fleet.lab ORDER BY fleet.lab
chart | g47_chart_success_by_lab | fleet | success_pct | lab | average
chart | g47_chart_success_by_verb | fleet | success_pct | verb | average
chart | g47_chart_median_duration | fleet | duration_s | lab | median
pivot | g47_pivot_lab_outcome | fleet | n | lab | outcome
chart | g47_chart_telemetry_speed | telemetry | speed | gripper_event | sum
