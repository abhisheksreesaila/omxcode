"""A 100k-row table for goal 68 M1's Learn (a robot's moments: speed, the nearest person, where), with the rule a person
would label by written in truth.json. pixi run python -I docs/goals/68/make_stops.py OUT_DIR"""
import csv
import json
import random
import sys
from pathlib import Path


def truth(speed, person):
    if speed >= 0.1:
        return "moving"
    return "person ahead" if person < 1.5 else "waiting"


out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
rng = random.Random(68)
rows = []
for i in range(100_000):
    stopped = rng.random() < 0.4
    speed = round(rng.uniform(0.0, 0.08) if stopped else rng.uniform(0.12, 1.5), 3)
    person = round(rng.uniform(0.3, 6.0), 2)
    rows.append({"t": round(i * 0.1, 1), "robot": rng.choice(["jackal-1", "jackal-2", "nova-1"]), "speed": speed, "turn_rate": round(rng.uniform(-0.6, 0.6), 2),
                 "person_m": person, "place": rng.choice(["corridor", "room", "door"])})
with open(out / "moments.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0]))
    w.writeheader()
    w.writerows(rows)
(out / "truth.json").write_text(json.dumps([truth(r["speed"], r["person_m"]) for r in rows]))
print(out / "moments.csv")
