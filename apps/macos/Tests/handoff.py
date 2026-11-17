#!/usr/bin/env python3
"""Handoff, in a hidden probe: what a window offers your other devices as its
tab in front changes, and a page another device hands over opening in a tab.

Build first (`./build.sh`), then `python3 Tests/handoff.py`. It runs in a test
world of its own with split_view.py's harness: started hidden, everything
removed afterwards. Whether another device really picks the page up needs two
devices on one Apple Account, and is checked by hand (apps/ios/README.md).
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("handoff-tests")
t = sv.T()


def offered():
    return sv.cmd({"do": "handoff"})


def urls():
    return [x["url"] for x in sv.sp("state")["tabs"]]


try:
    # Turned on, as Settings › General › Hand off pages to your other devices.
    sv.setup(handoff=True)
    sv.launch()

    a = sv.page("article")
    now = offered()
    t.ok("the tab in front's page is offered", now["url"] == f"{sv.BASE}/article", now)
    t.ok("as Eden's own activity", now["type"] == "com.subhajit.eden.beta.browsing", now)
    t.ok("named for the page", now["title"] == "article", now)

    sv.page("second")
    now = offered()
    t.ok("another tab in front: its page", now["url"] == f"{sv.BASE}/second", now)

    sv.sp("private")
    time.sleep(0.5)
    now = offered()
    t.ok("a private tab in front offers nothing", now["url"] == "" and now["type"] == "", now)

    sv.cmd({"do": "select", "id": a})
    time.sleep(0.5)
    now = offered()
    t.ok("back to an ordinary tab: its page again", now["url"] == f"{sv.BASE}/article", now)

    # A page handed over by another device.
    before = urls()
    got = sv.cmd({"do": "handoff", "action": "continue", "url": f"{sv.BASE}/handed"})
    time.sleep(0.8)
    t.ok("Eden's own activity is taken", got.get("taken") is True, got)
    t.ok("and its page opens in a tab", f"{sv.BASE}/handed" in urls(), (before, urls()))

    got = sv.cmd({"do": "handoff", "action": "continue", "url": f"{sv.BASE}/from-safari",
                  "type": "NSUserActivityTypeBrowsingWeb"})
    time.sleep(0.8)
    t.ok("a web page from another browser is taken", got.get("taken") is True, got)
    t.ok("and opens", f"{sv.BASE}/from-safari" in urls(), urls())

    before = urls()
    got = sv.cmd({"do": "handoff", "action": "continue", "url": f"{sv.BASE}/notes",
                  "type": "com.example.notes.editing"})
    time.sleep(0.5)
    t.ok("another app's activity is not taken", got.get("taken") is False, got)
    got = sv.cmd({"do": "handoff", "action": "continue", "url": "file:///etc/hosts"})
    time.sleep(0.5)
    t.ok("a page that isn't on the web is not taken", got.get("taken") is False, got)
    t.ok("and nothing opened for either", urls() == before, (before, urls()))
finally:
    t.done()
    sv.finish()
sys.exit(1 if t.failed else 0)
