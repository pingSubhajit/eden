"""Arc's folders survive an import, as folders of pinned rows (#478).

Build first (`./build.sh`), then `python3 Tests/arc_folders.py`. A made-up Arc
profile is written into the world's own Import folder, with two folders of
pinned pages, and the import is asked for its spaces. The folders have to come
in as folders of rows, every page a row in its own, and still be there when
Eden opens again.
"""
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# Its own world, apart from the split suite's in this checkout (see use()).
sv.use("arc-folders")

FOLDERS = {
    "Basics": [("Example", "https://example.com/"), ("IANA", "https://www.iana.org/")],
    "SRE": [("Docs", "https://www.rfc-editor.org/")],
}


def arc():
    """Arc as this world will find it: one space whose pinned list is two
    folders of pages."""
    root = f"{sv.SUPPORT}/Import/Arc"
    profile = f"{root}/User Data/Default"
    os.makedirs(profile, exist_ok=True)

    items = [{"id": "pinnedBox", "childrenIds": []}]
    for folder, pages in FOLDERS.items():
        box = f"box-{folder}"
        items[0]["childrenIds"].append(box)
        kids = []
        for n, (title, url) in enumerate(pages):
            tab = f"{box}-{n}"
            kids.append(tab)
            items.append({"id": tab, "title": title,
                          "data": {"tab": {"savedURL": url, "savedTitle": title}}})
        items.append({"id": box, "title": folder, "data": {"list": {}}, "childrenIds": kids})

    sidebar = {"sidebar": {"containers": [{
        "spaces": [{"title": "Fixture", "profile": {"default": {}},
                    "containerIDs": ["pinned", "pinnedBox"]}],
        "items": items,
    }]}}
    Path(f"{root}/StorableSidebar.json").write_text(json.dumps(sidebar))
    # A profile counts as one once it holds one of the files a browser keeps.
    Path(f"{profile}/History").write_bytes(b"")


def load(name):
    path = f"{sv.SUPPORT}/{name}"
    if not os.path.exists(path): return {}
    return json.load(open(path))


def groups():
    """Every space's kept groups (kept-groups.json), passing by the moves a
    file may keep beside them."""
    return [f for row in load("kept-groups.json").values() if isinstance(row, list) for f in row]


def names():
    """The folders of rows, kept groups now, by name, from every space."""
    return sorted(f["name"] for f in groups())


def filed():
    """Each row's page, with the name of the group it is in (its "folder"
    in pins.json, as it always was)."""
    folders = {f["id"]: f["name"] for f in groups()}
    return sorted((p["home"], folders.get(p.get("folder")))
                  for row in load("pins.json").values() for p in row if p.get("listed"))


WANT = sorted((url, folder) for folder, pages in FOLDERS.items() for _, url in pages)


def main():
    t = sv.T()
    try:
        sv.setup()
        arc()
        sv.launch()
        out = sv.cmd({"do": "import", "from": "Arc", "what": ["spaces"]})
        count = (out.get("arc") or {}).get("pins")
        t.ok("the pages came in as pins", count == 3, out)
        for _ in range(25):
            if names() and len(filed()) == 3: break
            time.sleep(0.2)
        t.ok("their folders are folders of rows", names() == ["Basics", "SRE"], names())
        t.ok("and every page is a row in its own", filed() == WANT, filed())
        tabs = sv.cmd({"do": "tabs"}).get("tabs", [])
        t.ok("nothing went into a tab group", not [x for x in tabs if x.get("group")],
             [(x["url"], x["group"]) for x in tabs])

        # Opened again, they are where they were.
        sv.quit()                       # quit, not finish: the world has to stay
        time.sleep(1)
        sv.launch()
        st = sv.cmd({"do": "pinfolder", "action": "state"})
        t.ok("the folders are still there when Eden opens again",
             names() == ["Basics", "SRE"] and filed() == WANT
             and sorted(f["name"] for f in st.get("folders") or []) == ["Basics", "SRE"], st)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
