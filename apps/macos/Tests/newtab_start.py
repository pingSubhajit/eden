#!/usr/bin/env python3
"""Before anything is typed, ⌘T's field lists your open tabs, most recent
first and not the one in front, then the sites you go to most that aren't
open, one row a site; never your history from a private tab. Return on the
empty field still opens nothing until an arrow key picks a row, and an open
tab picked is switched to rather than opened again. While typing, the open
tabs that answer to it come after the row Return takes.

Build first (`./build.sh` or `./build.sh debug`), then
`python3 Tests/newtab_start.py`. It uses the split suite's harness: started
hidden in a world of its own, keys pressed through the app's own event queue.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("newtab-start")


def cmd_t():
    sv.cmd({"do": "press", "code": 17, "chars": "t", "mods": ["cmd"], "letgo": True})
    time.sleep(0.8)


def bare(code, chars):
    sv.cmd({"do": "press", "code": code, "chars": chars, "mods": []})
    time.sleep(0.8)


def urls():
    return [t.get("url", "") for t in sv.cmd({"do": "tabs"})["tabs"]]


def world():
    """Alpha and Bravo open, Bravo in front; three other sites in history,
    Echo the most visited."""
    a = sv.page("alpha")
    b = sv.page("bravo")
    for site, count in (("https://foxtrot.example/", 1), ("https://echo.example/", 6), ("https://golf.example/", 3)):
        sv.cmd({"do": "history", "take": site, "count": count})
        time.sleep(0.05)
    sv.sp("select", id=b); time.sleep(0.5)
    return a, b


def main():
    t = sv.T()
    try:
        sv.setup()
        sv.launch()
        a, b = world()
        cmd_t()
        s = sv.cmd({"do": "suggest"})
        rows = s["offers"]
        kinds = [o[1] for o in rows]
        t.ok("⌘T, nothing typed: the list is there", s["editing"] and rows, rows)
        t.ok("an open tab first: Alpha, not Bravo, which is in front",
             rows and rows[0][1] == "open" and rows[0][2].endswith("/alpha")
             and not any(o[1] == "open" and o[2].endswith("/bravo") for o in rows), rows)
        # The test's own pages are a site in history too; the three are
        # read in their order among the rest.
        sites = [o[2] for o in rows if o[1] == "visited" and o[2].endswith(".example/")]
        t.ok("then the sites gone to most, Echo first, one row a site",
             sites == ["https://echo.example/", "https://golf.example/", "https://foxtrot.example/"], sites)
        t.ok("open tabs before sites", kinds.index("visited") > kinds.index("open"), kinds)

        count = len(urls())
        bare(36, "\r")
        t.ok("Return with nothing picked opens nothing", len(urls()) == count, urls())

        bare(125, "")
        bare(36, "\r")
        time.sleep(0.6)
        s = sv.cmd({"do": "suggest"})
        t.ok("↓ then Return on an open tab: switched to, nothing opened",
             s["address"].endswith("/alpha") and len(urls()) == count, (s["address"], urls()))

        sv.sp("select", id=b); time.sleep(0.5)
        cmd_t()
        sv.cmd({"do": "field", "text": "alph"}); time.sleep(0.6)
        s = sv.cmd({"do": "suggest"})
        rows = s["offers"]
        t.ok("typing: Alpha's tab among the rows, after the first",
             any(o[1] == "open" and o[2].endswith("/alpha") for o in rows[1:]) and rows[0][1] != "open", rows)
        bare(53, "\x1b")

        shy = sv.cmd({"do": "open", "url": f"{sv.BASE}/india", "private": True})
        time.sleep(0.8)
        sv.sp("select", id=shy["id"]); time.sleep(0.5)
        cmd_t()
        # What was typed a moment ago comes back with ⌘T, for 45 seconds.
        t.ok("⌘T brings back what was typed into the last one put away", sv.cmd({"do": "suggest"})["typed"] == "alph")
        # Emptied as a hand would, all of it chosen and deleted: the bench's
        # own `field` takes words, never nothing.
        sv.cmd({"do": "press", "code": 0, "chars": "a", "mods": ["cmd"]}); time.sleep(0.3)
        bare(51, "\x7f")
        s = sv.cmd({"do": "suggest"})
        t.ok("from a private tab: no history offered", not any(o[1] == "visited" for o in s["offers"]), s["offers"])
    finally:
        t.done()
        sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
