"""Stand-in for the skill's check_port.py (goal 64): `check_port.py <weights> --port-dir <dir>`."""
import subprocess
import sys
from pathlib import Path

folder = sys.argv[sys.argv.index("--port-dir") + 1]
sys.exit(subprocess.run([sys.executable, str(Path(__file__).parent / "_fake.py"), "build", folder]).returncode)
