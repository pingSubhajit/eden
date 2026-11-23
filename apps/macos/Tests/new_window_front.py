#!/usr/bin/env python3
"""A window just opened is the one in front (#1146), with the address field
up and no tab made, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/new_window_front.py`.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("new-window-front")
t = sv.T()
try:
    sv.setup(); sv.launch()
    sv.page("a")
    st = sv.cmd({"do": "windows", "action": "new"})
    ws = st["windows"]
    t.ok("two windows", len(ws) == 2, ws)
    t.ok("the new one is in front, with no click", len(ws) == 2 and ws[1]["front"] and not ws[0]["front"], [(w["n"], w["front"]) for w in ws])
    # ⌘N: the address field up over nothing in front, and no tab made for it.
    front = sv.cmd({"do": "launcher", "action": "state"})
    t.ok("⌘N raises the address field", front.get("editing") is True, front)
    t.ok("…with no tab made", front.get("tabs") == [] and front.get("active") == "", front)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
