#!/usr/bin/env python3
"""A pinned row that has left its page says so, and the page its home sends
it to as it loads is still home (#15).

Build first (`./build.sh`), then `python3 Tests/pin_away.py`. It uses the
split suite's harness: started hidden, in a world of its own, everything
removed afterwards. The row itself (the home's icon, the slash, the click on
the icon) is looked at in a live window by hand; this checks what the row
goes by, Tab.wandered.

The pages here are their own: /mail is a page the first time it is asked
for, and then sends you on to its inbox, as a mail app's address does once
you are signed in; /app does the same the second time with its own script,
once loaded; /chain, the second time, sends itself on with its script to a
page that takes seconds to send it on again, to its inbox.

A hand on the page is a key handed to it (the bench's `key`): after one,
where the page goes is yours, however soon.
"""
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("pin-away")

asked = {}


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        asked[path] = asked.get(path, 0) + 1
        if path == "/mail" and asked[path] > 1:
            self.send_response(302)
            self.send_header("Location", "/mail/inbox")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path == "/chain/step":
            time.sleep(2.5)
            self.send_response(302)
            self.send_header("Location", "/chain/inbox")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        script = ""
        if path == "/chain" and asked[path] > 1:
            script = ("<script>addEventListener('load', function () { setTimeout(function () {"
                      " location.href = '/chain/step' }, 200) })</script>")
        if path == "/app" and asked[path] > 1:
            script = ("<script>addEventListener('load', function () { setTimeout(function () {"
                      " history.replaceState(null, '', '/app/home') }, 200) })</script>")
        body = f"<!doctype html><title>{path.strip('/')}</title>{script}<p>{path}".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a): pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"


def tab(id):
    return next(x for x in sv.cmd({"do": "tabs"})["tabs"] if x["id"] == id)


def settle(id, path, within=10):
    """The tab at that path, done loading, and a moment more."""
    for _ in range(within * 10):
        now = tab(id)
        if now["url"] == BASE + path and not now["loading"]: break
        time.sleep(0.1)
    time.sleep(1.5)
    return tab(id)


def key(id):
    """A hand on the page: a key pressed on it."""
    sv.cmd({"do": "key", "id": id, "text": "x"})


def main():
    t = sv.T()
    try:
        sv.setup(); sv.launch()

        mail = sv.sp("open", url=f"{BASE}/mail")["resultID"]
        settle(mail, "/mail")
        sv.cmd({"do": "pin", "id": mail, "listed": True})
        t.ok("a pin at its home is home", tab(mail)["wandered"] is False, tab(mail))

        sv.cmd({"do": "go", "id": mail, "url": f"{BASE}/mail/letter"})
        now = settle(mail, "/mail/letter")
        t.ok("gone on to another page, it has left", now["wandered"] is True, now)

        sv.cmd({"do": "pin", "id": mail, "home": True})
        now = settle(mail, "/mail/inbox")
        t.ok("home again, sent on to its inbox as it loads: still home",
             now["url"] == f"{BASE}/mail/inbox" and now["wandered"] is False, now)

        sv.cmd({"do": "go", "id": mail, "url": f"{BASE}/mail/letter"})
        now = settle(mail, "/mail/letter")
        t.ok("on from the inbox, it has left", now["wandered"] is True, now)

        sv.cmd({"do": "go", "id": mail, "url": f"{BASE}/mail/inbox"})
        now = settle(mail, "/mail/inbox")
        t.ok("back at the inbox by hand, it is home", now["wandered"] is False, now)

        app = sv.sp("open", url=f"{BASE}/app")["resultID"]
        settle(app, "/app")
        sv.cmd({"do": "pin", "id": app, "listed": True})
        sv.cmd({"do": "go", "id": app, "url": f"{BASE}/app/other"})
        t.ok("a second pin gone on has left", settle(app, "/app/other")["wandered"] is True)
        sv.cmd({"do": "pin", "id": app, "home": True})
        now = settle(app, "/app/home")
        t.ok("a page that sends itself on once loaded lands at home",
             now["url"] == f"{BASE}/app/home" and now["wandered"] is False, now)

        # Script navigations both, one after a hand on the page.
        sv.ev(app, f"location.href = '{BASE}/app/by-itself'")
        now = settle(app, "/app/by-itself")
        t.ok("untouched, where the page sends itself is still home", now["wandered"] is False, now)
        # At home there, Back to Pinned Page would change its letter: the
        # address instead.
        sv.cmd({"do": "go", "id": app, "url": f"{BASE}/app"})
        settle(app, "/app/home")
        key(app)
        sv.ev(app, f"location.href = '{BASE}/app/clicked'")
        now = settle(app, "/app/clicked")
        t.ok("touched, where it goes at once is yours", now["wandered"] is True, now)

        chain = sv.sp("open", url=f"{BASE}/chain")["resultID"]
        settle(chain, "/chain")
        sv.cmd({"do": "pin", "id": chain, "listed": True})
        sv.cmd({"do": "go", "id": chain, "url": f"{BASE}/chain/other"})
        settle(chain, "/chain/other")
        sv.cmd({"do": "pin", "id": chain, "home": True})
        now = settle(chain, "/chain/inbox", within=15)
        t.ok("a slow chain of the home's own redirects ends at home",
             now["url"] == f"{BASE}/chain/inbox" and now["wandered"] is False, now)

        # Relaunched while away, it comes back at its home by its home's
        # title, the inbox's it was last seen with there, not by its host.
        sv.cmd({"do": "go", "id": mail, "url": f"{BASE}/mail/letter"})
        settle(mail, "/mail/letter")
        time.sleep(2)
        sv.quit(); sv.launch()
        back = [x for x in sv.cmd({"do": "tabs"})["tabs"] if x["url"] == f"{BASE}/mail"]
        t.ok("relaunched away from home, it is named as its home",
             len(back) == 1 and back[0]["title"] == "mail/inbox", back or sv.cmd({"do": "tabs"})["tabs"])

        loose = sv.sp("open", url=f"{BASE}/loose")["resultID"]
        settle(loose, "/loose")
        sv.cmd({"do": "go", "id": loose, "url": f"{BASE}/elsewhere"})
        t.ok("a tab that isn't a pin never has", settle(loose, "/elsewhere")["wandered"] is False)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
