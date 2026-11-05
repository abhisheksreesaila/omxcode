"""film.src.html → film.html: one file, the recorded Lisbon frames inlined (open it anywhere, post it, record it).

  pixi run python docs/launch/series/build_film.py
"""
import base64
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
run = json.loads((HERE / "lisbon" / "run.json").read_text())
for f in run["frames"]:
    f["f"] = "data:image/jpeg;base64," + base64.b64encode((HERE / "lisbon" / f["f"]).read_bytes()).decode()
src = (HERE / "film.src.html").read_text()
assert "__RUN__" in src
(HERE / "film.html").write_text(src.replace("__RUN__", json.dumps(run, ensure_ascii=False)))
print("film.html", round((HERE / "film.html").stat().st_size / 1e6, 2), "MB")
