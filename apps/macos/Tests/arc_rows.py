"""Arc's pinned list: every page becomes a row, what it filed a row in a
folder of that name (#478).

Build first (`./build.sh`), then `python3 Tests/arc_rows.py`. A made-up Arc
profile holds a favourite, a page loose in its pinned list, and two filed in a
folder. The favourite has to come in as a square, the loose page as a row
under the squares, and the filed ones as rows in a folder of rows named after
Arc's, so that neither the keeping nor the folder is lost. Nothing goes into a
tab group.
"""
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("arc-rows")


def arc():
    """A favourite, a page Arc keeps loose, and a folder holding two."""
    root = f"{sv.SUPPORT}/Import/Arc"
    profile = f"{root}/User Data/Default"
    os.makedirs(profile, exist_ok=True)
    items = [
        {"id": "favBox", "childrenIds": ["fav"]},
        {"id": "fav", "title": "Favourite",
         "data": {"tab": {"savedURL": "https://example.com/", "savedTitle": "Favourite"}}},
        {"id": "pinnedBox", "childrenIds": ["loose", "folder"]},
        {"id": "loose", "title": "Kept",
         "data": {"tab": {"savedURL": "https://www.iana.org/", "savedTitle": "Kept"}}},
        {"id": "folder", "title": "SRE", "data": {"list": {}}, "childrenIds": ["filed1", "filed2"]},
        {"id": "filed1", "title": "One",
         "data": {"tab": {"savedURL": "https://www.rfc-editor.org/", "savedTitle": "One"}}},
        {"id": "filed2", "title": "Two",
         "data": {"tab": {"savedURL": "https://www.ietf.org/", "savedTitle": "Two"}}},
    ]
    sidebar = {"sidebar": {"containers": [{
        "spaces": [{"title": "Fixture", "profile": {"default": {}},
                    "containerIDs": ["pinned", "pinnedBox"]}],
        "topAppsContainerIDs": [{"default": {}}, "favBox"],
        "items": items,
    }]}}
    Path(f"{root}/StorableSidebar.json").write_text(json.dumps(sidebar))
    Path(f"{profile}/History").write_bytes(b"")


def pins():
    path = f"{sv.SUPPORT}/pins.json"
    if not os.path.exists(path): return []
    return [p for row in json.load(open(path)).values() for p in row]


def folders():
    """The folders of rows, kept groups now (kept-groups.json), by id, from
    every space, passing by the moves the file may keep beside them."""
    path = f"{sv.SUPPORT}/kept-groups.json"
    if not os.path.exists(path): return {}
    return {f["id"]: f for row in json.load(open(path)).values() if isinstance(row, list) for f in row}


def main():
    t = sv.T()
    try:
        sv.setup()
        arc()
        sv.launch()
        out = sv.cmd({"do": "import", "from": "Arc", "what": ["spaces"]})
        for _ in range(25):
            if len(pins()) >= 4 and folders(): break
            time.sleep(0.2)
        t.ok("the import counts every page as a pin, and no tabs",
             (out.get("arc") or {}).get("pins") == 4 and "tabs" not in (out.get("arc") or {}), out.get("arc"))

        rows = [p for p in pins() if p.get("listed")]
        squares = [p for p in pins() if not p.get("listed")]
        t.ok("the favourite is a square", [p["home"] for p in squares] == ["https://example.com/"], squares)
        t.ok("every page of the pinned list is a row",
             sorted(p["home"] for p in rows)
             == ["https://www.iana.org/", "https://www.ietf.org/", "https://www.rfc-editor.org/"], rows)

        made = folders()
        named = {p["home"]: (made.get(p.get("folder")) or {}).get("name") for p in rows}
        t.ok("the folder Arc filed two in is a folder of rows", [f["name"] for f in made.values()] == ["SRE"], made)
        t.ok("the two it filed are rows in it, the loose one at the top",
             named == {"https://www.iana.org/": None, "https://www.rfc-editor.org/": "SRE",
                       "https://www.ietf.org/": "SRE"}, named)
        tabs = sv.cmd({"do": "tabs"}).get("tabs", [])
        t.ok("and nothing went into a tab group", not [x for x in tabs if x.get("group")],
             [(x["url"], x["group"]) for x in tabs])
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
