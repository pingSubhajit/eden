#!/usr/bin/env python3
"""Pins go back home, always: a pin closed with ⌘W, or open when Eden
quits, comes back at the page it was pinned at, as in Arc.

Build first (`./build.sh`), then `python3 Tests/pins_home.py`. It uses the
split suite's harness: started hidden, no window made or shown, everything
removed afterwards.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("pins-home")

t = sv.T()
def tab(st, id): return next(x for x in st["tabs"] if x["id"] == id)
def last(url): return url.rsplit("/", 1)[-1]
def pinned(st): return [last(tab(st, id)["url"]) for id in st["pins"]]
def pin(id, **f): return sv.cmd({"do": "pin", "id": id, **f})
def relaunch():
    sv.sp("save"); sv.quit()
    sv.launch(); time.sleep(0.5)
    return sv.sp("state")
def wander(id, to):
    sv.cmd({"do": "go", "id": id, "url": f"{sv.BASE}/{to}"}); sv.cmd({"do": "wait", "id": id}); time.sleep(0.3)

try:
    # "Pins keep their site" had a switch; an off left from then is let go
    # at launch, so the pins go home all the same.
    sv.setup(sidebar=True, **{"pins.home": False, "pins.peek": False}); sv.launch()
    a = sv.page("a"); sv.page("b")
    pin(a)

    wander(a, "away")
    t.ok("the pin goes where it is taken", last(tab(sv.sp("state"), a)["url"]) == "away")
    sv.sp("close", id=a); st = sv.sp("state")
    t.ok("⌘W puts it down at its pinned page, an old off or not", last(tab(st, a)["url"]) == "a", tab(st, a)["url"])
    sv.sp("save")
    entry = next(x for x in sv.session()["tabs"] if x.get("pin"))
    t.ok("the session holds it at its pinned page", last(entry["url"]) == "a" and last(entry["home"]) == "a", entry)
    sv.sp("select", id=a); sv.cmd({"do": "wait", "id": a}); time.sleep(0.3)
    t.ok("picked again, it opens its pinned page", last(tab(sv.sp("state"), a)["url"]) == "a", tab(sv.sp("state"), a)["url"])

    # Taken somewhere and left open when Eden quits.
    wander(a, "later")
    st = relaunch()
    t.ok("left elsewhere at quit, it opens again at home", pinned(st) == ["a"], pinned(st))
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
