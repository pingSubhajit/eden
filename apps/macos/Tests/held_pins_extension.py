#!/usr/bin/env python3
"""A pinned row held as data in a folded folder is a tab at rest to an
extension (#9, HeldPins.swift), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/held_pins_extension.py`. It
runs a copy of build/Eden.app under a bundle id of its own, hidden, in a
world of its own with split_view.py's harness; the copy, its WebKit folders
and the world are removed afterwards.

What is checked, with an extension that has the "tabs" permission and
keeps what chrome.tabs tells it: pinned rows in a folder, folded and
relaunched so they are held as data, are listed by chrome.tabs.query at
their pages; unfolding the folder and folding it again keeps their ids
and tells the extension nothing of them, while a tab opened meanwhile is
told; and on rows held, chrome.tabs.update brings one in front, or sends
it to another page, and chrome.tabs.reload loads one, each under the id
it has, and chrome.tabs.move puts another row at one's place, in the
folder; a folder carried past a row, its rows held, tabs or both, is
told as moved by its rows and not the row it passed; in a folder half
held, a row moved among its rows, into it or out of it lands exactly,
the held row staying in it, held. And chrome.tabs.move as the API has
it, for ordinary tabs too: one id or several, each to the place after
where the one before it landed (forward, back and both), taking the
group of where it lands and told of it in onUpdated, -1 for the end, a
windowId to go to another window, tabs staying after the pins, an error
for a bad id, onMoved, onDetached and onAttached told once for each tab
moved and never for one it passed, and a tab sent to another window
neither woken nor put in front, a page of a split taking the split with
it."""
import json
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("held-pins-extension")
BUNDLE = "com.subhajit.eden.beta.heldpins"
work = Path(tempfile.mkdtemp(prefix="eden-heldpins-"))

FILES = {
    "manifest.json": json.dumps({
        "manifest_version": 3, "name": "Held Rows", "version": "1.0",
        "permissions": ["tabs", "tabGroups", "storage"],
        "background": {"service_worker": "background.js"},
        "externally_connectable": {"matches": ["http://127.0.0.1/*"]},
    }),
    "background.js": """
// What it was told, kept in storage: a worker may be put away between asks.
let queue = Promise.resolve();
const note = (event) => {
  queue = queue.then(() => chrome.storage.local.get({ events: [] }))
    .then(({ events }) => chrome.storage.local.set({ events: [...events, event] }));
};
chrome.tabs.onCreated.addListener((t) => note("created:" + t.id));
chrome.tabs.onRemoved.addListener((id) => note("removed:" + id));
chrome.tabs.onMoved.addListener((id, info) => note("moved:" + id + ":" + info.fromIndex + ":" + info.toIndex));
chrome.tabs.onDetached.addListener((id) => note("detached:" + id));
chrome.tabs.onAttached.addListener((id, info) => note("attached:" + id + ":" + info.newWindowId));
chrome.tabs.onUpdated.addListener((id, info) => { if ("groupId" in info) note("grouped:" + id + ":" + info.groupId); });
chrome.runtime.onMessageExternal.addListener((message, sender, reply) => {
  const failed = (e) => reply({ error: String(e && e.message) });
  if (message.type === "query") {
    chrome.tabs.query({}).then((tabs) => reply(tabs.map((t) => ({ id: t.id, url: t.url, pinned: t.pinned, active: t.active, index: t.index, windowId: t.windowId, groupId: t.groupId }))));
  } else if (message.type === "activate") {
    chrome.tabs.update(message.id, { active: true }).then((t) => reply({ id: t && t.id }), failed);
  } else if (message.type === "go") {
    chrome.tabs.update(message.id, { url: message.url }).then((t) => reply({ id: t && t.id }), failed);
  } else if (message.type === "reload") {
    chrome.tabs.reload(message.id).then(() => reply({ ok: true }), failed);
  } else if (message.type === "move") {
    chrome.tabs.move(message.ids, message.props)
      .then((t) => reply({ tabs: (Array.isArray(t) ? t : [t]).map((x) => ({ id: x.id, index: x.index, windowId: x.windowId, pinned: x.pinned })) }), failed);
  } else if (message.type === "windows") {
    chrome.windows.getAll({}).then((w) => reply(w.map((x) => x.id)), failed);
  } else {
    queue.then(() => chrome.storage.local.get({ events: [] })).then((r) => reply(r));
  }
  return true;
});
""",
}

ASK = """(function (ext, message) {
  window.__r = null;
  chrome.runtime.sendMessage(ext, message, (r) => { window.__r = r || { none: String(chrome.runtime.lastError && chrome.runtime.lastError.message) }; });
})(%s, %s); 1"""


def probe_copy():
    app = work / "Eden.app"
    shutil.copytree(Path(sv.ROOT, "build", "Eden.app"), app, symlinks=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE}", str(app / "Contents/Info.plist")], check=True)
    (app / "Contents/embedded.provisionprofile").unlink(missing_ok=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--entitlements", str(Path(sv.ROOT, "Eden.entitlements")), "--deep", str(app)],
                   check=True, capture_output=True)
    return str(app)


def ev(id, js):
    return sv.cmd({"do": "eval", "id": id, "js": js}).get("value")


def pf(**f): return sv.cmd({"do": "pinfolder", **f})


def loaded(name):
    for _ in range(80):
        ext = next((x for x in sv.cmd({"do": "extensions"})["extensions"] if x["name"] == name and x["loaded"]), None)
        if ext: return ext
        time.sleep(0.25)
    return None


def main():
    t = sv.T()
    folder = work / "ext"
    folder.mkdir()
    for name, body in FILES.items(): (folder / name).write_text(body)
    sv.APP = probe_copy()
    try:
        sv.setup(splitView=True, **{"start.fresh": False, "tabs.groups": True})
        sv.launch()
        sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
        t.ok("the extension loads", loaded("Held Rows") is not None)

        # Four pinned rows in a folder, folded, and one at the top;
        # relaunched, the folder's hold nothing their pins don't, and are
        # held as data.
        a, b, d, f, e = (sv.page(n) for n in ("a", "b", "d", "f", "e"))
        for id in (a, b, d, f, e): pf(action="pin", id=id)
        pf(action="new", name="Work", id=a)
        for id in (b, d, f): pf(action="move", id=id, folder="Work")
        # Another page in front, so neither row is the tab you were on.
        sv.page("front")
        pf(action="fold", name="Work")
        sv.quit(); sv.launch()
        ext = loaded("Held Rows")
        t.ok("it loads again", ext is not None)
        if not ext: return t
        listed = sv.page("listed")
        held = pf(action="state").get("held") or []
        t.ok("the folder's rows are held as data", sorted(x[0] for x in held) == ["a", "b", "d", "f"], held)

        def ask(message):
            ev(listed, ASK % (json.dumps(ext["id"]), json.dumps(message)))
            for _ in range(80):
                got = ev(listed, "JSON.stringify(window.__r || null)")
                if got and got != "null": return json.loads(got)
                time.sleep(0.25)
            return None

        def rows():
            tabs = ask({"type": "query"}) or []
            return {t["url"].rstrip("/").rsplit("/", 1)[-1]: t for t in tabs if isinstance(t, dict) and t.get("url")}

        def events():
            return (ask({"type": "events"}) or {}).get("events", [])

        def told(ids, kinds=("created", "removed")):
            return [e for e in events() if e.split(":")[0] in kinds and int(e.split(":")[1]) in ids]

        first = rows()
        t.ok("chrome.tabs.query lists them, pinned, at their pages", all(first.get(k, {}).get("pinned") for k in ("a", "b", "d", "f")), first)
        ids = {first[k]["id"] for k in ("a", "b", "d", "f") if k in first}

        pf(action="open", name="Work")
        time.sleep(1.5)
        unfolded = rows()
        t.ok("unfolded: the same ids", {unfolded[k]["id"] for k in ("a", "b", "d", "f") if k in unfolded} == ids, (first, unfolded))
        pf(action="fold", name="Work")
        time.sleep(1.5)
        folded = rows()
        t.ok("folded again: the same ids", {folded[k]["id"] for k in ("a", "b", "d", "f") if k in folded} == ids, folded)
        t.ok("neither told as removed or created", told(ids) == [], told(ids))

        target = first.get("a", {}).get("id")
        answer = ask({"type": "activate", "id": target})
        t.ok("chrome.tabs.update on a held row answers with its id", (answer or {}).get("id") == target, answer)
        time.sleep(1)
        front = next((x for x in sv.cmd({"do": "tabs"})["tabs"] if x.get("active")), {})
        t.ok("and brings it in front", front.get("url", "").rstrip("/").endswith("/a"), front)
        after = rows()
        t.ok("under the same id", after.get("a", {}).get("id") == target and after.get("a", {}).get("active"), after.get("a"))
        t.ok("still nothing told of it", told(ids) == [], told(ids))

        # A row moved to a held row's place goes there, into the folder,
        # and is told as moved, once.
        now = rows()
        e_id = now.get("e", {}).get("id")
        answer = ask({"type": "move", "ids": e_id, "props": {"index": now.get("b", {}).get("index")}})
        t.ok("chrome.tabs.move to a held row's place answers with the tab", ((answer or {}).get("tabs") or [{}])[0].get("id") == e_id, answer)
        saved = pf(action="state").get("saved") or []
        t.ok("and the row is there, in the folder, before it",
             saved[:5] == [["a", "Work"], ["e", "Work"], ["b", "Work"], ["d", "Work"], ["f", "Work"]], saved)
        time.sleep(1)
        t.ok("told as moved once", len(told({e_id}, ("moved",))) == 1, told({e_id}, ("moved",)))

        # Reloaded, or sent elsewhere, a held row is its tab under its id.
        target = now.get("d", {}).get("id")
        answer = ask({"type": "reload", "id": target})
        t.ok("chrome.tabs.reload of a held row answers", (answer or {}).get("ok") is True, answer)
        time.sleep(1)
        t.ok("its tab made, at its page, under its id", rows().get("d", {}).get("id") == target, rows().get("d"))
        target = now.get("f", {}).get("id")
        answer = ask({"type": "go", "id": target, "url": sv.BASE + "/elsewhere"})
        t.ok("chrome.tabs.update with a url on a held row answers with its id", (answer or {}).get("id") == target, answer)
        gone = None
        for _ in range(20):
            gone = rows().get("elsewhere")
            if gone: break
            time.sleep(0.25)
        t.ok("and it goes there under that id", (gone or {}).get("id") == target, gone)
        t.ok("none of it told as removed or created", told(ids | {now.get("e", {}).get("id")}) == [],
             told(ids | {now.get("e", {}).get("id")}))

        # A folder carried past a row is told as moved by its rows, held
        # as data, tabs or some of each, and the row it passed isn't.
        marks = work / "Held Move.html"
        marks.write_text("<DL><p>\n" + "".join(f'<DT><A HREF="{sv.BASE}/{n}">{n}</A>\n' for n in ("hm1", "hm2")) + "</DL>\n")
        sv.cmd({"do": "import-file", "path": str(marks)})
        g = sv.page("g")
        pf(action="pin", id=g)
        time.sleep(1)
        def top():
            st = pf(action="state")
            title = next((o[1] for o in st.get("order", []) if o[0] == g), None)
            return ["g" if l[0] == "pin" and l[2] == title else l[2] for l in st.get("lines", []) if l[1] == 0]
        def past_g(name, members):
            items = top()
            if "g" not in items or name not in items: return False, items
            now = rows()
            mine = {now[k]["id"] for k in members if k in now}
            seen = len(events())
            # Taken out, then put at g's place: after g from before it,
            # before g from after it.
            pf(action="place", name=name, index=items.index("g"))
            time.sleep(1.5)
            told = {int(e.split(":")[1]) for e in events()[seen:] if e.startswith("moved:")}
            return told == mine and now["g"]["id"] not in told, (items, top(), told, mine, now.get("g", {}).get("id"))
        held_names = ("hm1", "hm2")
        ok, seen = past_g("Held Move Bookmarks", held_names)
        t.ok("a folder of rows held as data moved past a row: its rows told as moved, not the row", ok, seen)
        ok, seen = past_g("Work", ("a", "e", "b", "d", "elsewhere"))
        t.ok("a folder of tabs and held rows moved past it: the same", ok, seen)
        pf(action="open", name="Held Move Bookmarks")
        time.sleep(1)
        ok, seen = past_g("Held Move Bookmarks", held_names)
        t.ok("a folder of tabs moved past it: the same", ok, seen)

        # A folder half held, hh1 and hh3 tabs, hh2 held: a move among its
        # rows, into it or out of it, lands exactly, as the extension sees
        # the row, and the held row stays in it, held.
        half = work / "Half Held.html"
        half.write_text("<DL><p>\n" + "".join(f'<DT><A HREF="{sv.BASE}/{n}">{n}</A>\n' for n in ("hh1", "hh2", "hh3")) + "</DL>\n")
        sv.cmd({"do": "import-file", "path": str(half)})
        hh = "Half Held Bookmarks"
        o = sv.page("o")
        pf(action="pin", id=o)
        for n in ("hh1", "hh3"):
            ask({"type": "activate", "id": rows()[n]["id"]})
            time.sleep(1)
        sv.sp("select", id=listed)
        time.sleep(1)
        def in_folder():
            return [r[0] for r in pf(action="state").get("saved", []) if r[1] == hh and r[0].startswith("hh")]
        def held_rows():
            return [r[0] for r in pf(action="state").get("held", []) if r[1] == hh and r[0].startswith("hh")]
        t.ok("a folder half held: hh1 and hh3 tabs, hh2 held", held_rows() == ["hh2"] and in_folder() == ["hh1", "hh2", "hh3"],
             (held_rows(), in_folder()))
        def moved_as_asked(name, to, among):
            now = rows()
            everything = sorted(now, key=lambda n: now[n]["index"])
            at = now[to]["index"]
            everything.remove(name)
            everything.insert(at, name)
            ask({"type": "move", "ids": now[name]["id"], "props": {"index": at}})
            time.sleep(1)
            after = rows()
            got = sorted(among, key=lambda n: after[n]["index"])
            want = [n for n in everything if n in among]
            return got == want, (want, got, in_folder(), held_rows())
        ok, seen = moved_as_asked("hh1", "hh3", ("hh1", "hh2", "hh3"))
        t.ok("a tab of it moved past the held row to another's place goes exactly there",
             ok and in_folder() == ["hh2", "hh3", "hh1"] and held_rows() == ["hh2"], seen)
        ok, seen = moved_as_asked("g", "hh3", ("g", "hh1", "hh2", "hh3"))
        t.ok("a row from outside moved to a tab's place in it goes exactly there", ok and "hh2" in held_rows(), seen)
        ok, seen = moved_as_asked("hh3", "o", ("hh1", "hh2", "hh3", "o"))
        t.ok("a tab of it moved out goes exactly there, the held row left in it, held",
             ok and "hh3" not in in_folder() and held_rows() == ["hh2"], seen)
        # Carried in the column, as the bench lets a row go beside another:
        # hh1 put before g, the folder's other tab.
        ids = {x.get("url", "").rstrip("/").rsplit("/", 1)[-1]: x.get("id") for x in sv.cmd({"do": "tabs"})["tabs"]}
        pf(action="move", id=ids.get("hh1"), folder=hh, anchor=ids.get("g"))
        now = rows()
        t.ok("a tab of it carried before another stays there, the held row still in it, held",
             now["hh1"]["index"] + 1 == now["g"]["index"] and held_rows() == ["hh2"] and "hh2" in in_folder(),
             ({n: now.get(n, {}).get("index") for n in ("hh1", "hh2", "g")}, in_folder(), held_rows()))

        # Ordinary tabs, as the API moves them.
        x, y, z = (sv.page(n) for n in ("x", "y", "z"))
        time.sleep(1)
        now = rows()
        mine = now["x"]["windowId"]
        loose = sorted((t for t in (ask({"type": "query"}) or []) if t.get("windowId") == mine and not t.get("pinned")),
                       key=lambda t: t["index"])
        last = max(t["index"] for t in (ask({"type": "query"}) or []) if t.get("windowId") == mine)
        x_id, y_id, z_id = now["x"]["id"], now["y"]["id"], now["z"]["id"]
        answer = ask({"type": "move", "ids": x_id, "props": {"index": -1}})
        moved = ((answer or {}).get("tabs") or [{}])[0]
        t.ok("a tab moved to index -1 goes to the end, and says so", moved.get("id") == x_id and moved.get("index") == last, (answer, last))
        time.sleep(1)
        t.ok("told as moved once, and no other tab", len(told({x_id}, ("moved",))) == 1 and told({y_id, z_id}, ("moved",)) == [],
             [e for e in events() if e.startswith("moved:")])
        # Moved one place, past one tab: that tab isn't the one told.
        place = rows()["z"]["index"]
        answer = ask({"type": "move", "ids": z_id, "props": {"index": place + 1}})
        nxt = next((t for t in (ask({"type": "query"}) or []) if t.get("windowId") == mine and t.get("index") == place), {})
        time.sleep(1)
        t.ok("a tab moved past the next is told as moved, once, and the next isn't",
             len(told({z_id}, ("moved",))) == 1 and told({nxt.get("id")}, ("moved",)) == [] and nxt.get("id") != z_id,
             ([e for e in events() if e.startswith("moved:")], nxt, answer))
        answer = ask({"type": "move", "ids": [y_id, z_id], "props": {"index": 0}})
        both = (answer or {}).get("tabs") or []
        first_loose = min(t["index"] for t in loose)
        t.ok("several ids go in their order, and a tab stays after the pins",
             [t.get("id") for t in both] == [y_id, z_id] and [t.get("index") for t in both] == [first_loose, first_loose + 1]
             and not any(t.get("pinned") for t in both), (answer, first_loose))
        answer = ask({"type": "move", "ids": 987654, "props": {"index": 0}})
        t.ok("a bad id is an error", "No tab with id" in str((answer or {}).get("error")), answer)
        answer = ask({"type": "move", "ids": [x_id, 987654], "props": {"index": 0}})
        t.ok("and fails the whole call, nothing moved", "error" in (answer or {}) and rows()["x"]["index"] == last, (answer, rows().get("x")))
        # Several ids, each to the place after where the one before it
        # landed, as the API moves them: two moved forward together don't
        # stay together.
        pages = {n: sv.page(n) for n in ("p", "q", "r", "s")}
        time.sleep(1)
        def four():
            now = rows()
            return sorted(("p", "q", "r", "s"), key=lambda n: now[n]["index"])
        def several(names, index):
            now = rows()
            return ask({"type": "move", "ids": [now[n]["id"] for n in names], "props": {"index": index}})
        def arranged():
            several(["p", "q", "r", "s"], -1)
            return rows()["p"]["index"]
        base = arranged()
        several(["p", "q"], base + 2)
        t.ok("several moved forward: [p, q, r, s], p and q to 2, is [r, p, s, q]", four() == ["r", "p", "s", "q"], four())
        base = arranged()
        several(["r", "s"], base)
        t.ok("several moved back: r and s to 0 is [r, s, p, q]", four() == ["r", "s", "p", "q"], four())
        base = arranged()
        several(["s", "p"], base + 1)
        t.ok("one back and one forward: s and p to 1 is [s, q, p, r]", four() == ["s", "q", "p", "r"], four())
        base = arranged()
        several(["p", "q"], -1)
        t.ok("several to -1 go to the end in their order: [r, s, p, q]", four() == ["r", "s", "p", "q"], four())
        # A row held as data, never opened, sent anywhere by chrome.tabs.move
        # lands exactly there: at a held row of another folded folder, of its
        # own, at a tab of a folder half held, at the top, and among the
        # tabs, where a pin stops at the last row; held again in a folder.
        for name, rows_ in (("SrcF", ("sa1", "sa2", "sa3")), ("DstF", ("da1", "da2"))):
            marks = work / (name + ".html")
            marks.write_text("<DL><p>\n" + "".join(f'<DT><A HREF="{sv.BASE}/{n}">{n}</A>\n' for n in rows_) + "</DL>\n")
            sv.cmd({"do": "import-file", "path": str(marks)})
        time.sleep(1)
        src, dst = "SrcF Bookmarks", "DstF Bookmarks"
        def held_in(folder):
            return [r[0] for r in pf(action="state").get("held", []) if r[1] == folder]
        def saved_in(folder):
            return [r[0] for r in pf(action="state").get("saved", []) if r[1] == folder]
        t.ok("two folded folders of rows held as data", held_in(src) == ["sa1", "sa2", "sa3"] and held_in(dst) == ["da1", "da2"],
             (held_in(src), held_in(dst)))
        ok, seen = moved_as_asked("sa1", "da2", ("sa1", "sa2", "sa3", "da1", "da2"))
        t.ok("a held row sent to a held row of another folder goes there, held there",
             ok and saved_in(dst) == ["da1", "da2", "sa1"] and "sa1" in held_in(dst), (seen, saved_in(dst), held_in(dst)))
        ok, seen = moved_as_asked("sa2", "sa3", ("sa2", "sa3"))
        t.ok("a held row sent to a held row of its own folder goes there", ok and saved_in(src) == ["sa3", "sa2"], (seen, saved_in(src)))
        ok, seen = moved_as_asked("da1", "g", ("da1", "g", "hh1", "hh2"))
        t.ok("a held row sent to a tab of a folder half held goes there, in that folder", ok and "da1" in saved_in(hh), (seen, saved_in(hh)))
        ok, seen = moved_as_asked("sa3", "o", ("sa3", "o"))
        top = [r for r in pf(action="state").get("saved", []) if r[0] == "sa3"]
        t.ok("a held row sent to a row at the top goes there, out of its folder", ok and top and top[0][1] is None, (seen, top))
        gx = sv.page("gx")
        sv.cmd({"do": "group", "id": gx, "new": True, "name": "GX"})
        time.sleep(1)
        now = rows()
        answer = ask({"type": "move", "ids": now["sa2"]["id"], "props": {"index": now["gx"]["index"]}})
        now = rows()
        pinned = [r for r in now.values() if r.get("windowId") == now["sa2"]["windowId"] and r.get("pinned")]
        t.ok("a held row sent among the tabs stops at the last row, a pin still",
             "error" not in (answer or {}) and now["sa2"].get("pinned") and now["sa2"]["index"] == max(r["index"] for r in pinned),
             (answer, now.get("sa2"), max((r["index"] for r in pinned), default=None)))

        # With groups on, a tab moved lands where it was sent and takes the
        # group of where it lands: out of its group's span it leaves it,
        # between two of a group's tabs it joins it, at a group's edge it is
        # in none.
        ks = {n: sv.page(n) for n in ("k1", "k2", "k3", "k4", "k5")}
        sv.cmd({"do": "group", "id": ks["k1"], "new": True, "name": "G"})
        for n in ("k2", "k3"): sv.cmd({"do": "group", "id": ks[n], "name": "G"})
        time.sleep(1)
        def tabs_now():
            return {t["url"].rstrip("/").rsplit("/", 1)[-1]: t for t in (ask({"type": "query"}) or []) if isinstance(t, dict) and t.get("url")}
        def k_order():
            now = tabs_now()
            return sorted((n for n in ks if n in now), key=lambda n: now[n]["index"])
        def group_of(n):
            return tabs_now().get(n, {}).get("groupId")
        def send(names, index):
            now = tabs_now()
            return ask({"type": "move", "ids": [now[n]["id"] for n in names], "props": {"index": index}})
        # k4 and k5 to the end, after the group: in none still.
        send(["k4", "k5"], -1)
        g = group_of("k1")
        t.ok("a group of k1, k2 and k3, then k4 and k5", g not in (None, -1) and [group_of(n) for n in ("k2", "k3")] == [g, g]
             and k_order() == ["k1", "k2", "k3", "k4", "k5"] and [group_of(n) for n in ("k4", "k5")] == [-1, -1],
             (k_order(), [group_of(n) for n in ks]))
        heard = len(events())
        send(["k3"], -1)
        now = tabs_now()
        t.ok("a tab of a group moved forward out of it goes there and leaves the group",
             now["k3"]["index"] == max(x["index"] for x in now.values() if x.get("windowId") == now["k3"]["windowId"])
             and now["k3"].get("groupId") == -1, (k_order(), group_of("k3")))
        send(["k3"], tabs_now()["k2"]["index"])
        t.ok("moved between two tabs of a group, it joins it",
             k_order()[:3] == ["k1", "k3", "k2"] and group_of("k3") == g, (k_order(), group_of("k3")))
        send(["k5"], tabs_now()["k2"]["index"] + 1)
        t.ok("moved to a group's edge, it is in none", k_order() == ["k1", "k3", "k2", "k5", "k4"] and group_of("k5") == -1,
             (k_order(), group_of("k5")))
        # k5 before the group, in none, for k1 to be sent back past.
        send(["k5"], tabs_now()["k1"]["index"])
        before_group = tabs_now()["k5"]["index"]
        send(["k1"], before_group)
        now = tabs_now()
        t.ok("a tab of a group moved back out of it goes there and leaves the group",
             now["k1"]["index"] == before_group and now["k1"].get("groupId") == -1, (k_order(), now["k1"]))
        send(["k4", "k5"], -1)
        send(["k4", "k5"], tabs_now()["k2"]["index"])
        t.ok("several moved back between two tabs of a group join it, in their order",
             k_order() == ["k1", "k3", "k4", "k5", "k2"] and [group_of(n) for n in ("k3", "k4", "k5", "k2")] == [g, g, g, g],
             (k_order(), [group_of(n) for n in ks]))
        k3_id = tabs_now()["k3"]["id"]
        time.sleep(1)
        grouped = [e for e in events()[heard:] if e.startswith("grouped:%d:" % k3_id)]
        t.ok("told of each change of group by onUpdated, once each, -1 for none",
             grouped == ["grouped:%d:-1" % k3_id, "grouped:%d:%d" % (k3_id, g)], grouped)
        # Only the tab named moves, not the tabs picked with it in the
        # column, which a drag of it would carry; they stay picked.
        picked = sv.sp("pick", ids=[pages["p"], pages["q"]]).get("selected")
        several(["p"], rows()["r"]["index"])
        t.ok("a tab picked with another moves alone: p to r's place is [p, r, s, q]", four() == ["p", "r", "s", "q"], four())
        t.ok("and the pick stays as it was", sv.sp("state").get("selected") == picked and set(picked or []) >= {pages["p"], pages["q"]},
             (picked, sv.sp("state").get("selected")))
        sv.cmd({"do": "split", "action": "pick", "ids": []})

        sv.cmd({"do": "windows", "action": "new"})
        windows = ask({"type": "windows"}) or []
        other = next((w for w in windows if w != mine), None)
        t.ok("a second window", other is not None, windows)
        # Asleep and not in front, it goes as it is: neither window's tab in
        # front changes, and it doesn't wake.
        sv.sp("select", id=x)
        sv.cmd({"do": "sleep", "id": y})
        def fronts():
            return [(w.get("active"), w.get("awake")) for w in sv.cmd({"do": "windows"})["windows"]]
        before = [w.get("active") for w in sv.cmd({"do": "windows"})["windows"]]
        answer = ask({"type": "move", "ids": y_id, "props": {"windowId": other, "index": -1}})
        went = ((answer or {}).get("tabs") or [{}])[0]
        t.ok("a tab moved to another window by its windowId is there", went.get("windowId") == other, answer)
        time.sleep(1)
        after = sv.cmd({"do": "windows"})["windows"]
        t.ok("neither window's tab in front changed", [w.get("active") for w in after] == before, (before, fronts()))
        t.ok("and it didn't wake", not any(u.rstrip("/").endswith("/y") for w in after for u in w.get("awake", [])), fronts())
        time.sleep(1)
        t.ok("told as detached and attached, once each",
             len(told({y_id}, ("detached",))) == 1 and len(told({y_id}, ("attached",))) == 1,
             [e for e in events() if e.split(":")[0] in ("detached", "attached")])
        answer = ask({"type": "move", "ids": now["a"]["id"], "props": {"windowId": other, "index": -1}})
        t.ok("a pin, in every window already, doesn't go to another", "error" in (answer or {}), answer)
        answer = ask({"type": "move", "ids": rows()["da2"]["id"], "props": {"windowId": other, "index": -1}})
        t.ok("nor a row held as data: the call fails, and it stays held where it was",
             "error" in (answer or {}) and rows()["da2"]["windowId"] == mine and "da2" in held_in(dst), (answer, rows().get("da2")))
        # A page of a split takes the split with it, whole: both pages in
        # the other window, in their order and a split there, neither in
        # front nor woken, each told as detached and attached, and the
        # answer the tab named alone.
        s1, s2 = sv.page("s1"), sv.page("s2")
        sv.sp("pair", id=s2, **{"with": s1}, side="right")
        time.sleep(0.8)
        sv.sp("select", id=x)
        for page in (s1, s2): sv.cmd({"do": "sleep", "id": page})
        time.sleep(1)
        here = next((p.get("tabs") for p in sv.sp("state").get("splits", []) if set(p.get("tabs", [])) == {s1, s2}), None)
        t.ok("a split of s1 and s2", here is not None, sv.sp("state").get("splits"))
        now = rows()
        s1_id, s2_id = now["s1"]["id"], now["s2"]["id"]
        before = [w.get("active") for w in sv.cmd({"do": "windows"})["windows"]]
        answer = ask({"type": "move", "ids": s2_id, "props": {"windowId": other, "index": -1}})
        went = (answer or {}).get("tabs") or []
        time.sleep(1.5)
        after = rows()
        there = sv.cmd({"do": "split", "action": "state", "window": 2}).get("splits", [])
        t.ok("a page of a split sent to another window takes the split: both there, in order, a split",
             after["s1"]["windowId"] == other and after["s2"]["windowId"] == other
             and abs(after["s2"]["index"] - after["s1"]["index"]) == 1 and any(p.get("tabs") == here for p in there),
             (after.get("s1"), after.get("s2"), here, there))
        windows = sv.cmd({"do": "windows"})["windows"]
        t.ok("neither window's tab in front changed, and neither page woke",
             [w.get("active") for w in windows] == before
             and not any(u.rstrip("/").endswith(("/s1", "/s2")) for w in windows for u in w.get("awake", [])),
             (before, [(w.get("active"), w.get("awake")) for w in windows]))
        t.ok("the answer is the tab named alone", [w.get("id") for w in went] == [s2_id], answer)
        t.ok("each page told as detached and attached, once",
             all(len(told({i}, ("detached",))) == 1 and len(told({i}, ("attached",))) == 1 for i in (s1_id, s2_id)),
             [e for e in events() if e.split(":")[0] in ("detached", "attached")])

        # While a tab opened meanwhile is told, as ever: the extension hears.
        def created():
            return [e for e in (ask({"type": "events"}) or {}).get("events", []) if e.startswith("created:")]
        before = len(created())
        sv.page("c")
        heard = False
        for _ in range(20):
            if len(created()) > before: heard = True; break
            time.sleep(0.25)
        t.ok("a tab opened meanwhile is told as created", heard, created())
    finally:
        sv.finish()
        for kind in ("WebKit", "Caches", "HTTPStorages"):
            shutil.rmtree(Path.home() / "Library" / kind / BUNDLE, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)
    return t


if __name__ == "__main__":
    t = main()
    t.done()
    sys.exit(1 if t.failed else 0)
