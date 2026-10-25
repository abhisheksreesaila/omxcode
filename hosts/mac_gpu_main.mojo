# Mac entry point for a native build on a Mac with its GPU (scripts/build.sh with MAC_GPU set, on macOS): Mojo's own
# `main`, so `mojo build` links and starts Mojo's runtime, which the GPU path needs (the cross build's hosts/mac_main.mojo
# starts at `_mojo_entry` with a stand-in runtime and no GPU).
from app import Main
from mojoui.hosts.appkit import run


def main():
    _ = run[Main]()
