#!/usr/bin/env python3
"""What fifteen hundred pinned rows in a folded folder cost (#9), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/pin_cost.py`. Brings in a
bookmarks file of 1,500 pages in 30 folders, as Import does, into the one
folder named after the file, folded (it comes in folded); then opens a
second window, and renames the folder with both open, then again with 750
more rows unfolded beside them, which are tabs. Prints how long each took,
as PIN-COST lines, and checks that the folded folder's rows are kept as
pins, not tabs, in either window. Nothing is shown: a hidden app draws
nothing, so what is timed is the windows' own work, not drawing it
(PinCostTests times that).
"""
import shutil
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("pin-cost")
t = sv.T()
PAGES, FOLDERS = 1500, 30


def pf(**f): return sv.cmd({"do": "pinfolder", **f})


def windows(**f):
    # The bench answers 0.6 s after it acts, for the window to settle.
    began = time.time()
    answer = sv.cmd({"do": "windows", **f})
    return answer, time.time() - began - 0.6


folder = Path(tempfile.mkdtemp(prefix="eden-pin-cost-"))


def bookmarks(name, site, pages):
    """A bookmarks file of `pages` pages in FOLDERS folders, as one exports."""
    html = ["<DL><p>"]
    for f in range(FOLDERS):
        html.append(f"<DT><H3>Folder {f}</H3><DL><p>")
        for p in range(pages // FOLDERS):
            n = f * (pages // FOLDERS) + p
            html.append(f'<DT><A HREF="https://{site}-{n}.example/">Page {n}</A>')
        html.append("</DL><p>")
    html.append("</DL>")
    file = folder / f"{name}.html"
    file.write_text("\n".join(html))
    return file


try:
    sv.setup(); sv.launch()
    file = bookmarks("Pin Cost", "pin-cost", PAGES)

    began = time.time()
    took = sv.cmd({"do": "import-file", "path": str(file)})
    imported = time.time() - began
    t.ok("every page came in", took.get("bookmarks") == PAGES, took.get("said"))
    st = pf(action="state")
    group = next((g for g in st.get("folders", []) if g["name"] == "Pin Cost Bookmarks"), None)
    t.ok("in the folder named after the file", group is not None, st.get("folders"))
    t.ok("which comes in folded", bool(group and group["collapsed"]), group)
    if group and not group["collapsed"]:
        pf(action="fold", name="Pin Cost Bookmarks")
    st = pf(action="state")
    t.ok("its rows are kept as pins, not tabs", len(st.get("held", [])) == PAGES and len(st.get("order", [])) == 0,
         (len(st.get("held", [])), len(st.get("order", []))))

    listed, opening = windows(action="new")
    tabs = [len(w["tabs"]) for w in listed["windows"]]
    t.ok("a second window makes no tab for them either", len(tabs) == 2 and max(tabs) < 10, tabs)

    began = time.time()
    pf(action="rename", name="Pin Cost Bookmarks", to="Kept")
    renamed = time.time() - began

    # Half as many again on show beside them, in a folder unfolded: the
    # pins held are looked for among 750 tabs each time the pins change.
    sv.cmd({"do": "import-file", "path": str(bookmarks("Pin Cost Open", "pin-cost-open", PAGES // 2))})
    pf(action="open", name="Pin Cost Open Bookmarks")
    listed = sv.cmd({"do": "windows"})
    shown = [len(w["tabs"]) for w in listed["windows"]]
    t.ok("an unfolded folder's rows are tabs in both windows", min(shown) >= PAGES // 2, shown)
    began = time.time()
    pf(action="rename", name="Kept", to="Kept Again")
    mixed = time.time() - began

    print(f"PIN-COST import of {PAGES}: {imported * 1000:.0f} ms")
    print(f"PIN-COST another window: {opening * 1000:.0f} ms; tabs in each window: {tabs}")
    print(f"PIN-COST the folder renamed, both windows following: {renamed * 1000:.0f} ms")
    print(f"PIN-COST with {PAGES // 2} more unfolded, the folder renamed, both following: {mixed * 1000:.0f} ms; tabs: {shown}")
finally:
    t.done(); sv.finish()
    shutil.rmtree(folder, ignore_errors=True)
sys.exit(1 if t.failed else 0)
