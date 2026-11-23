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
and chrome.tabs.move, where the shim answers it, puts another row at one's
place, in the folder.
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
        "permissions": ["tabs", "storage"],
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
chrome.runtime.onMessageExternal.addListener((message, sender, reply) => {
  const failed = (e) => reply({ error: String(e && e.message) });
  if (message.type === "query") {
    chrome.tabs.query({}).then((tabs) => reply(tabs.map((t) => ({ id: t.id, url: t.url, pinned: t.pinned, active: t.active, index: t.index }))));
  } else if (message.type === "activate") {
    chrome.tabs.update(message.id, { active: true }).then((t) => reply({ id: t && t.id }), failed);
  } else if (message.type === "go") {
    chrome.tabs.update(message.id, { url: message.url }).then((t) => reply({ id: t && t.id }), failed);
  } else if (message.type === "reload") {
    chrome.tabs.reload(message.id).then(() => reply({ ok: true }), failed);
  } else if (message.type === "move") {
    chrome.tabs.move(message.id, { index: message.index }).then((t) => reply({ id: t && t.id }), failed);
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
        sv.setup(**{"start.fresh": False})
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

        def told(ids):
            events = (ask({"type": "events"}) or {}).get("events", [])
            return [e for e in events if int(e.split(":")[1]) in ids]

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

        # A row moved to a held row's place goes there, into the folder:
        # when the shim answers chrome.tabs.move. A WebKit that has its own
        # answers it itself, and has said it isn't implemented, here as on
        # main; HeldPinsTests asks the shim's own move then.
        now = rows()
        answer = ask({"type": "move", "id": now.get("e", {}).get("id"), "index": now.get("b", {}).get("index")})
        if "not implemented" in str((answer or {}).get("error", "")):
            print("  skip  chrome.tabs.move is WebKit's own here, not implemented:", answer)
        else:
            t.ok("chrome.tabs.move to a held row's place answers", "error" not in (answer or {"error": None}), answer)
            saved = pf(action="state").get("saved") or []
            t.ok("and the row is there, in the folder, before it",
                 saved[:5] == [["a", "Work"], ["e", "Work"], ["b", "Work"], ["d", "Work"], ["f", "Work"]], saved)

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
