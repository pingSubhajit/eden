"""Arc's folders, in every space, survive ⌘Q and a relaunch.

Build first (`./build.sh`), then `python3 Tests/spaces_quit_keep.py`. A
made-up Arc profile with two spaces, each with a loose pinned page and a
folder of two, is imported into a hidden probe (tab groups on); the probe
goes through the spaces, opens a tab of its own in each, quits the way ⌘Q
does, and is started again, twice. Since pins replaced bookmarks (c7cbe10),
Arc's pinned list comes in as the space's pinned rows, each folder a folder
of rows, kept in pins.json and kept-groups.json rather than as a tab group
in the space's session file. Every space must still keep its folder with
both its pages, on disk and in its rows, and its loose Arc page as a row.

Then the same with Settings › General › Start with a fresh window on, which
is where they were lost (Varun, 1.0.5): a fresh start kept each space's pins
and nothing else, so every folder Arc had went at the next launch. A fresh
start keeps the pinned rows and their folders, and lets the tab opened in
each space go, as the switch says. And a space gone to after a fresh start
opens with nothing in front, not its first pin.

Nothing here makes, shows or brings forward a window.
"""
import glob
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("hub-sp-quit")

SPACES = {
    "Work": {"loose": [("Ex", "https://example.com/")],
             "folders": {"Basics": [("IANA", "https://www.iana.org/"), ("RFC", "https://www.rfc-editor.org/")]}},
    "Study": {"loose": [("W3", "https://www.w3.org/")],
              "folders": {"Reading": [("WHATWG", "https://whatwg.org/"), ("MDN", "https://developer.mozilla.org/")]}},
}
FOLDERS = {name: next(iter(s["folders"])) for name, s in SPACES.items()}
# The page each space's own loose pinned page is titled.
ROWS = {name: s["loose"][0][0] for name, s in SPACES.items()}
# A tab of the space's own, not pinned, opened by the probe.
OWN = {name: f"own-{name.lower()}" for name in SPACES}
PAGES = {name: sorted(u for _, u in next(iter(s["folders"].values()))) for name, s in SPACES.items()}


def arc():
    """Two Arc spaces, each a loose page and one folder of two, and a
    favourite above them."""
    root = f"{sv.SUPPORT}/Import/Arc"
    profile = f"{root}/User Data/Default"
    os.makedirs(profile, exist_ok=True)
    items, spaces = [], []
    for name, s in SPACES.items():
        box = f"pin-{name}"
        kids = []
        for i, (title, url) in enumerate(s["loose"]):
            kids.append(f"{box}-l{i}")
            items.append({"id": kids[-1], "title": title, "data": {"tab": {"savedURL": url, "savedTitle": title}}})
        for folder, pages in s["folders"].items():
            fid = f"{box}-{folder}"
            kids.append(fid)
            inside = []
            for i, (title, url) in enumerate(pages):
                inside.append(f"{fid}-{i}")
                items.append({"id": inside[-1], "title": title, "data": {"tab": {"savedURL": url, "savedTitle": title}}})
            items.append({"id": fid, "title": folder, "data": {"list": {}}, "childrenIds": inside})
        items.append({"id": box, "childrenIds": kids})
        spaces.append({"title": name, "profile": {"default": {}}, "containerIDs": ["pinned", box]})
    items.append({"id": "fav", "childrenIds": ["fav-0"]})
    items.append({"id": "fav-0", "title": "GH", "data": {"tab": {"savedURL": "https://github.com/", "savedTitle": "GH"}}})
    sidebar = {"sidebar": {"containers": [{"spaces": spaces, "items": items,
                                           "topAppsContainerIDs": [{"default": {}}, "fav"]}]}}
    Path(f"{root}/StorableSidebar.json").write_text(json.dumps(sidebar))
    Path(f"{profile}/History").write_bytes(b"")


def ids():
    """The spaces by name, from the world's own list."""
    return {s["name"]: s["id"] for s in json.load(open(f"{sv.SUPPORT}/spaces.json"))}


def kept(space):
    """What is kept on disk for a space, by its id: its folders by name with
    the pages in each, and every page it has pinned."""
    def read(name):
        path = f"{sv.SUPPORT}/{name}"
        return json.load(open(path)) if os.path.exists(path) else {}
    rows = read("pins.json").get(space, [])
    folders = {g["id"]: g["name"] for g in read("kept-groups.json").get(space, [])}
    out = {}
    for row in rows:
        if row.get("folder") in folders:
            out.setdefault(folders[row["folder"]], []).append(row["home"])
    return {k: sorted(v) for k, v in out.items()}, [row["home"] for row in rows]


def go(name):
    index = list(ids()).index(name) + 1
    sv.cmd({"do": "space", "action": "go", "index": index})
    time.sleep(1)
    return sv.cmd({"do": "tabs"})["tabs"]


def rows():
    """The pinned rows of the space on screen, as drawn: title and folder."""
    return [(title, folder) for _, title, folder in sv.cmd({"do": "pinfolder", "action": "state"})["order"]]


def row_folders(drawn):
    out = {}
    for _, folder in drawn:
        if folder:
            out[folder] = out.get(folder, 0) + 1
    return out


def run(t, fresh):
    tag = "fresh: " if fresh else ""
    sv.setup(**{"tabs.groups": True, "start.fresh": fresh})
    arc()
    sv.launch()
    out = sv.cmd({"do": "import", "from": "Arc", "what": ["spaces"]}).get("arc") or {}
    # Each space's three pinned pages, and Arc's favourite in each.
    t.ok(tag + "the two spaces and their pins came in", out.get("spaces") == 2 and out.get("pins") == 8, out)
    time.sleep(1.5)
    for name in SPACES:
        go(name)
        sv.page(OWN[name])
    for turn in (1, 2):
        sv.quit()
        time.sleep(1)
        for name in SPACES:
            folders, homes = kept(ids()[name])
            t.ok(f"{tag}quit {turn}: {name}'s folder is kept, both pages",
                 folders == {FOLDERS[name]: PAGES[name]}, (folders, homes))
        sv.launch()
        time.sleep(1)
        for name in SPACES:
            tabs = go(name)
            drawn = rows()
            t.ok(f"{tag}relaunch {turn}: {name} shows its folder with both pages",
                 row_folders(drawn) == {FOLDERS[name]: 2}, drawn)
            t.ok(f"{tag}relaunch {turn}: {name}'s loose Arc page is a row of its own",
                 (ROWS[name], None) in drawn, drawn)
            loose = any(x["url"].endswith("/" + OWN[name]) for x in tabs)
            if fresh:
                # Last time's tabs go, as the switch says; the pins stay.
                t.ok(f"{tag}relaunch {turn}: {name}'s own tab is gone", not loose, [x["title"] for x in tabs])
                if turn == 1:
                    st = sv.sp("state")
                    f = next((x for x in st["tabs"] if x["id"] == st["activeID"]), None)
                    t.ok(f"{tag}relaunch {turn}: {name} opens with nothing in front, not its pin, and no empty tab",
                         f is None and not any(x["blank"] for x in st["tabs"]), (f, st["pins"]))
            else:
                t.ok(f"{tag}relaunch {turn}: {name}'s own tab is still there", loose, [x["url"] for x in tabs])
    sv.finish()


def main():
    t = sv.T()
    try:
        run(t, fresh=False)
        run(t, fresh=True)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
