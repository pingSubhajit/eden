#!/usr/bin/env python3
"""No line under the pins without pins (idea 444), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/pin_line.py`. It uses the
split suite's harness: started hidden in a world of its own, nothing shown,
everything removed afterwards. The one line between what is kept and the
tabs (#6), Clear on it, is drawn only with something kept above it: a pin
of this space, square or row, a folder of rows, or another device's group.
A group of yours isn't kept: it is among your tabs, under the line. And
only one line, ever. Read through the bench's `columnscroll`
(how many lines the column draws), in the column and as icons only. The row
across the top already drew its line only beside a pin (TabBar.showsPinLine).
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("pin-line")

t = sv.T()
def lines(): time.sleep(0.6); return sv.cmd({"do": "columnscroll"})["lines"]


def main():
    try:
        sv.setup(**{"tabs.groups": True, "sidebar": True}); sv.launch()
        a, b = sv.page("a"), sv.page("b")
        for layout in ("left", "icons"):
            sv.cmd({"do": "settings", "set": "tabs.layout", "value": layout})
            t.ok(f"{layout}: no pins, no groups: no line", lines() == 0, lines())
            sv.cmd({"do": "pin", "id": a})
            t.ok(f"{layout}: a square pinned: the line", lines() == 1, lines())
            sv.cmd({"do": "pin", "id": a, "off": True})
            t.ok(f"{layout}: unpinned again: gone", lines() == 0, lines())
            sv.cmd({"do": "pin", "id": a, "listed": True})
            t.ok(f"{layout}: pinned as a row: the line", lines() == 1, lines())
            sv.cmd({"do": "pin", "id": a, "off": True})
            sv.cmd({"do": "group", "id": a, "new": True, "name": "Open"})
            t.ok(f"{layout}: a group and no pin: nothing kept, no line", lines() == 0, lines())
            sv.cmd({"do": "pin", "id": b})
            t.ok(f"{layout}: a square over the group: one line", lines() == 1, lines())
            sv.cmd({"do": "pin", "id": b, "off": True})
            sv.cmd({"do": "group", "id": a, "name": "none"})
            t.ok(f"{layout}: the group gone, no pin: no line", lines() == 0, lines())
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
