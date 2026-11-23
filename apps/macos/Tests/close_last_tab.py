#!/usr/bin/env python3
"""Closing the tab in front goes back to the tab you were on before it, and a
close never makes a new tab (Browser.landing), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/close_last_tab.py` from a
worktree. With two pins and one ordinary tab beside them:

- ⌘W on the ordinary tab lands on the pin you were on before it, not on a
  new tab, and makes none;
- ⌘W on that pin puts it down and lands on the pin before it, and ⌘W on the
  last pin leaves nothing in front: the pins, the window open, no new tab.
  The pin put down first is not gone back to;
- ⇧⌘T brings the page back, in front;
- closed in the background, a tab takes nothing from the pin on screen;
- with another ordinary tab you were on, that one is gone back to;
- ⌘W with nothing in front closes the window.

The window was made by the probe and is never shown.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# Its own world, apart from the split suite's in this checkout (see use()).
sv.use("close-last-tab")


def name(st, id):
    return next((x["url"].rsplit("/", 1)[-1] for x in st["tabs"] if x["id"] == id), None)


def loose(st):
    return [x["id"] for x in st["tabs"] if x["id"] not in st["pins"]]


def blanks(st):
    return [x["id"] for x in st["tabs"] if x.get("blank")]


def only(*keep):
    """Every tab that isn't a pin closed, except those kept."""
    for id in loose(sv.sp("state")):
        if id not in keep:
            sv.sp("close", id=id)


def cmd_w():
    sv.cmd({"do": "press", "code": 13, "chars": "w", "mods": ["cmd"]}); time.sleep(0.6)
    return sv.sp("state")


def main():
    t = sv.T()
    try:
        sv.setup(**sv.IN_ORDER); sv.launch()
        st = sv.sp("state")
        t.ok("a window opens with nothing in front, and no tab made for it",
             st["activeID"] is None and st["tabs"] == [], st)
        a = sv.page("a"); p = sv.page("p")
        sv.cmd({"do": "pin", "id": a}); sv.cmd({"do": "pin", "id": p})
        sv.sp("select", id=a); time.sleep(0.3)
        sv.sp("select", id=p); time.sleep(0.3)
        b = sv.page("b")
        only(b)
        st = sv.sp("state")
        t.ok("two pins, and b the one tab beside them, on screen",
             sorted(st["pins"]) == sorted([a, p]) and loose(st) == [b] and st["activeID"] == b, st)

        # The case in the issue: ⌘W on the last ordinary tab.
        st = cmd_w()
        t.ok("⌘W on b: back to the pin you were on before it", st["activeID"] == p, st)
        t.ok("no new tab is made", blanks(st) == [] and loose(st) == [], st["tabs"])
        t.ok("the pins are still there", sorted(st["pins"]) == sorted([a, p]), st["pins"])

        st = cmd_w()
        t.ok("⌘W on that pin: put down, back to the pin before it", st["activeID"] == a, st)
        st = cmd_w()
        t.ok("⌘W on the last pin: nothing in front, not the pin put down",
             st["activeID"] is None, st)
        t.ok("…the pins stay, and no tab is made", sorted(sv.order(st)) == sorted([a, p]) and blanks(st) == [], st["tabs"])

        st = sv.sp("reopen"); time.sleep(0.5)
        t.ok("⇧⌘T brings b back, on screen", name(st, st["activeID"]) == "b", st)

        # Closed in the background, it takes nothing from the pin on screen.
        c = sv.page("c")
        only(c)
        sv.sp("select", id=a); time.sleep(0.3)
        st = sv.sp("close", id=c)
        t.ok("closing it behind a pin leaves the pin on screen", st["activeID"] == a, st)

        # Another ordinary tab you were on: that one, not a pin.
        d = sv.page("d"); e = sv.page("e")
        only(d, e)
        sv.sp("select", id=d); time.sleep(0.3)
        st = cmd_w()
        t.ok("with another tab you were on, that one is gone back to", st["activeID"] == e, st)
        t.ok("and no new tab is made for it", loose(st) == [e] and blanks(st) == [], st["tabs"])

        # Nothing in front, ⌘W closes the window, as on a lone empty tab.
        sv.sp("close", id=e); time.sleep(0.3)
        st = sv.sp("state")
        for _ in range(4):
            if st["activeID"] is None: break
            st = cmd_w()
        t.ok("nothing in front before the last ⌘W", st["activeID"] is None, st)
        cmd_w()
        w = sv.cmd({"do": "windows"})["windows"]
        t.ok("⌘W with nothing in front closes the window", not any(x["open"] for x in w), w)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
