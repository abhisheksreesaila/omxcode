"""Unicode's own conformance lines (BidiCharacterTest.txt, 91,000 of them) in test_bidi's form:
   curl -o build/BidiCharacterTest.txt https://www.unicode.org/Public/16.0.0/ucd/BidiCharacterTest.txt
   python3 tests/bidi_ucd.py > build/bidi-ucd.txt"""
from pathlib import Path
for l in (Path(__file__).resolve().parents[1] / "build/BidiCharacterTest.txt").read_text().splitlines():
    p = l.split(";")
    if l.startswith("#") or len(p) < 5:
        continue
    print({"0": 0, "1": 1, "2": -1}[p[1]], p[2], ",".join(x.lower() for x in p[0].split()), ",".join("-1" if x == "x" else x for x in p[3].split()), ",".join(p[4].split()) or "-")
