#!/usr/bin/env python3
"""A link's small window comes alone, and is always on (Little.swift), in a
hidden probe.

Build first (`./build.sh`), then `python3 Tests/little_alone.py`. It uses the
split suite's harness in a world of its own (little-alone): started hidden,
no window shown, everything removed afterwards. Nothing here touches the
pasteboard.

- A launch made by a link (EDEN_LINK, taken where the Apple Event would
  be): exactly one small window, and every browser window kept away and off
  screen — still so a few seconds on, after SwiftUI has done all it does at
  launch with its window.
- A link while the app is hidden, as ⌘H leaves it (a probe always starts
  hidden): its small window, and the browser's window kept away rather than
  shown again with it.
- Small windows are on for every install, one from before (sv.setup writes
  "welcomed") with the old switch off included, and the switch's line goes.
"""
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("little-alone")
t = sv.T()


def windows(**f): return sv.cmd({"do": "windows", **f})
def setting(key):
    out = subprocess.run(["defaults", "read", sv.SUITE, key], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else None


def launch_with(link):
    """sv.launch, handed a link to launch with."""
    if os.path.exists(sv.SOCK): os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"EDEN_PROBE={sv.W}", "--env", f"EDEN_LINK={link}", sv.APP])
    for _ in range(150):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update((sv.running() - before) & sv.holding())


def alone(st, link):
    return st["littles"] == [link] and st["keptAway"] and st["windows"] \
        and all(w["away"] and not w["shown"] for w in st["windows"] if w["open"])


try:
    # A launch made by a link, with two windows saved from last time.
    sv.setup(**{"links.little": True}); sv.launch()
    windows(action="new"); time.sleep(1)
    sv.quit()
    launch_with(f"{sv.BASE}/cold")
    st = windows()
    t.ok("cold launch: one small window, the browser's kept away", alone(st, f"{sv.BASE}/cold"), st)
    time.sleep(4)
    st = windows()
    t.ok("and still so a few seconds on", alone(st, f"{sv.BASE}/cold"), st)
    sv.quit()

    # A plain launch, then a link while the app is hidden.
    sv.setup(**{"links.little": True}); sv.launch()
    st = windows()
    t.ok("a plain launch keeps nothing away", not st["keptAway"], st)
    windows(action="link", url=f"{sv.BASE}/hidden"); time.sleep(1)
    st = windows()
    t.ok("hidden: one small window, the browser's kept away", alone(st, f"{sv.BASE}/hidden"), st)
    sv.cmd({"do": "little", "what": "keep"}); time.sleep(1)
    st = windows()
    t.ok("Open in Eden brings them back with the page",
         not st["keptAway"] and not any(w["away"] for w in st["windows"])
         and any(f"{sv.BASE}/hidden" in w["tabs"] for w in st["windows"]), st)
    sv.quit()

    # Always on (#41): an install from before, its old switch off, gets a
    # small window too, and the switch's line is gone.
    sv.setup(**{"links.little": False}); sv.launch()
    windows(action="link", url=f"{sv.BASE}/old"); time.sleep(1)
    st = windows()
    t.ok("an install from before: the link gets a small window", st["littles"] == [f"{sv.BASE}/old"], st["littles"])
    sv.quit()
    t.ok("and the old switch's line is gone", setting("links.little") is None, setting("links.little"))
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
