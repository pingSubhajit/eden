#!/usr/bin/env python3
"""Keys typed while a question hangs from the window stay with the question.

Build first, then `python3 Tests/dialog_keys.py`. Two made-up passwords are
brought in, the passwords page opened, and its Remove All… asked: "Remove 2
Passwords?" hangs from the window. Esc typed there is the question's. The
window's own Escape closes the panel in front, and used to take the key
first: the panel went, and the question stayed up with Return still on its
button. (That Esc then cancels the question is AppKit's, and needs the
question to be the key window, which a probe started hidden never has:
checked by hand.) It asked the bookmarks list's Remove before bookmarks left
the Mac (#6).
"""
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# Its own world, apart from the split suite's in this checkout (see use()).
sv.use("dialog-keys")


def main():
    t = sv.T()
    csv = f"{sv.SUPPORT}-seed.csv"
    try:
        sv.setup(); sv.launch()
        with open(csv, "w") as f:
            f.write("url,username,password\nhttps://one.example/,dlg-one,dlg-pass-one\n"
                    "https://two.example/,dlg-two,dlg-pass-two\n")
        took = sv.cmd({"do": "import-file", "path": csv})
        t.ok("two made-up passwords brought in", took.get("kept") == 2, took)

        sv.cmd({"do": "ui", "passwords": True}); time.sleep(0.5)
        asked = sv.cmd({"do": "passwords", "filter": "dlg-", "remove": True}); time.sleep(0.8)
        st = sv.cmd({"do": "probe"})
        t.ok("asked: the question is up over the panel", st["sheet"] and st["passwords"], (asked, st))

        sv.cmd({"do": "press", "code": 53, "chars": "\u001b", "sheet": True}); time.sleep(0.8)
        st = sv.cmd({"do": "probe"})
        t.ok("Esc: the panel under the question stays", st["passwords"], st)
        left = sv.cmd({"do": "passwords", "filter": "dlg-"})
        t.ok("Esc: the passwords stay", left.get("shown") == 2, left)
    finally:
        # The made-up passwords out of this world's keychain items.
        sv.cmd({"do": "ui", "confirm": "on"})
        sv.cmd({"do": "passwords", "filter": "dlg-", "remove": True})
        if os.path.exists(csv): os.unlink(csv)
        t.done(); sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
