#!/usr/bin/env python3
"""e5-small-v2 (intfloat, MIT) as a pack: classify()'s model (goal 51 M2, D-4919). Build side.

    pixi run python scripts/packs/e5small.py build/packs/e5small

Same graph and files as scripts/packs/minilm.py (MAX's BERT graph, mean pooled, 384 numbers); every text starts with
"query: ", as the model's card asks for symmetric tasks like classification.
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import minilm  # noqa: E402

if __name__ == "__main__":
    minilm.main(repo="intfloat/e5-small-v2", name="e5small", prefix="query: ")
