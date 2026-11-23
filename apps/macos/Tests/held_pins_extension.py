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
their pages; unfolding the folder and folding it again keeps their ids and
tells the extension nothing of them, while a tab opened meanwhile is told;
and on rows held, chrome.tabs.update brings one in front, or sends it to
another page, and chrome.tabs.reload loads one, each under the id it has,
and chrome.tabs.move puts another row at one's place, in the folder. And
chrome.tabs.move as the API has it, for ordinary tabs too: one id or
several, each to the place after where the one before it landed
(forward, back and both), taking the group of where it lands, -1 for the
end, a windowId to go to another window, tabs staying after the pins, an
error for a bad id, and onMoved, onDetached and onAttached told once for
each tab moved.
"""
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
        sv.setup(**{"start.fresh": False, "tabs.groups": True})
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
        answer = ask({"type": "move", "ids": y_id, "props": {"windowId": other, "index": -1}})
        went = ((answer or {}).get("tabs") or [{}])[0]
        t.ok("a tab moved to another window by its windowId is there", went.get("windowId") == other, answer)
        time.sleep(1)
        t.ok("told as detached and attached, once each",
             len(told({y_id}, ("detached",))) == 1 and len(told({y_id}, ("attached",))) == 1,
             [e for e in events() if e.split(":")[0] in ("detached", "attached")])
        answer = ask({"type": "move", "ids": now["a"]["id"], "props": {"windowId": other, "index": -1}})
        t.ok("a pin, in every window already, doesn't go to another", "error" in (answer or {}), answer)

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
