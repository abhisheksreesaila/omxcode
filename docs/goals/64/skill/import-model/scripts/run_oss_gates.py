"""Stand-in for the skill's run_oss_gates.py (goal 64): `run_oss_gates.py <repo> --port-dir <dir> --phase verify …`."""
import subprocess
import sys
from pathlib import Path

folder = sys.argv[sys.argv.index("--port-dir") + 1]
sys.exit(subprocess.run([sys.executable, str(Path(__file__).parent / "_fake.py"), "verify", folder]).returncode)
