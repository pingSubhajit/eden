#!/usr/bin/env python3
"""The last loose tab closed beside tab groups goes back to the tab you were
on before it, and never leaves a new tab (Browser.landing).

Build first (`./build.sh`), then `python3 Tests/close_beside_groups.py`. A
hidden probe (tab groups on, Start with a fresh window off) holds a folded
group of two pages and one loose page:

- closing the loose page goes back to the page of the group you were on
  before it, and makes no new tab;
- ⇧⌘T brings the page back;
- with the group's pages put away, closing the loose page leaves nothing in
  front: no new tab, the folder as it was, and the window open;
- a loose tab closed among other loose tabs goes back to the one you were on
  before it, not into the folder.

Nothing here makes, shows or brings forward a window.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-va2-close")


def group(**f): return sv.cmd({"do": "group", **f})


def front():
    st = sv.sp("state")
    return next((x for x in st["tabs"] if x["id"] == st["activeID"]), None), st


def blanks(st): return [x["id"] for x in st["tabs"] if x.get("blank")]


def main():
    t = sv.T()
    try:
        sv.setup(**{"tabs.groups": True, "start.fresh": False})
        sv.launch()
        pages = [sv.page(n) for n in ("alpha", "beta")]
        group(id=pages[0], new=True, name="Folder")
        group(id=pages[1], name="Folder")
        # Opened beside a page of the group, it would join it: taken out.
        loose = sv.page("gamma")
        group(id=loose, name="none")
        # Alpha, then the loose page: alpha is the tab before it.
        sv.sp("select", id=pages[0]); time.sleep(0.4)
        sv.sp("select", id=loose); time.sleep(0.4)
        if not group()["groups"][0]["collapsed"]:
            group(name="Folder", fold=True)
        g = group()
        t.ok("a folded group of two, one loose page in front",
             len(g["groups"]) == 1 and g["groups"][0]["collapsed"] and len(g["groups"][0]["tabs"]) == 2, g)

        sv.sp("closeTab", id=loose); time.sleep(0.5)
        f, st = front()
        t.ok("closing the loose page goes back to the page you were on before it",
             f and f["id"] == pages[0], f)
        t.ok("no new tab is made", blanks(st) == [] and len(st["tabs"]) == 2, st["tabs"])

        sv.sp("reopen"); time.sleep(0.8)
        f, st = front()
        t.ok("⇧⌘T brings the page back", f and f["url"].endswith("/gamma"), f)
        loose = f["id"] if f else loose

        # The group's pages put away from their rows: nothing open in it to
        # go back to.
        for page in pages:
            sv.sp("closeTab", id=page); time.sleep(0.4)
        if not group()["groups"][0]["collapsed"]:
            group(name="Folder", fold=True)
        sv.sp("closeTab", id=loose); time.sleep(0.5)
        f, st = front()
        t.ok("with the group's pages put away, nothing in front", st["activeID"] is None, st)
        t.ok("…and no new tab", blanks(st) == [] and sorted(sv.order(st)) == sorted(pages), st["tabs"])
        g = group()
        t.ok("the folder stays as it was, folded, with its two pages",
             g["groups"] and g["groups"][0]["collapsed"] and len(g["groups"][0]["tabs"]) == 2, g)
        w = sv.cmd({"do": "windows"})["windows"]
        t.ok("and the window stays open", any(x["open"] for x in w), w)

        # A loose tab among other loose tabs: back to the one you were on.
        delta = sv.page("delta"); group(id=delta, name="none")
        epsilon = sv.page("epsilon"); group(id=epsilon, name="none")
        sv.sp("select", id=epsilon); time.sleep(0.3)
        sv.sp("select", id=delta); time.sleep(0.3)
        sv.sp("closeTab", id=delta); time.sleep(0.5)
        f, st = front()
        t.ok("a loose tab among loose tabs goes back to the one before, not into the folder",
             f and f["id"] == epsilon, f)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
