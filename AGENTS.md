# Working on Eden

Rules for agents working in this repository.

## Product

- Eden is built for its owner and a few like-minded people, not for
  everyone. Prefer one opinionated behaviour over a setting.
- No AI features unless the owner asks for one. Don't extend the existing AI
  code (`AI.swift`, `AIAssist.swift` and the rest), and ask before touching
  or removing it.
- The Mac is sidebar-only from here on. Don't invest in the top tab bar
  (`TabBar.swift`).
- Borrow the best of other browsers, and copy outright where the owner says
  so (Dia's tab groups and toasts). Adapt colours to Eden's palette.
- Avoid noise. For example, no toast for something a well-known shortcut
  already covers, such as ⇧⌘T after closing a tab.

## Code

- Comments explain why, in plain prose that matches the existing files.
- No force-unwraps on anything that can fail. No new dependencies. No
  warnings you introduced.
- Shared code goes in `packages/EdenCore`, so the Mac and iPhone behave the
  same.
- No real keys or tokens anywhere, including tests and logs.

## Review and commit

- When a piece of work is done, get an independent review from GPT-6.1 Sol
  at high effort.
  - Give the reviewer the code and context, not your conclusions.
  - Ask it to cover correctness, architecture, optimisation, readability,
    formatting and data modelling.
  - Fix what it finds and send a fresh review each time, until nothing is
    blocking.
- Then make logical conventional commits (`feat`, `fix`, `docs` and so on,
  with scopes such as `core`, `macos` and `ios`), each one building on its
  own, and push to `main`.
- Commit only your own changes. Other sessions may have unfinished work in
  the same tree, so never sweep it into your commits.
- Every fix or feature adds its line to `CHANGELOG.md` under Unreleased.

## Build and install

- Mac: `apps/macos/build.sh`, then quit Eden, copy `build/Eden.app` into
  `/Applications` with `ditto`, and reopen it.
  - Install only if the build itself succeeded
    (`if ./build.sh > log; then …`), never through a pipe.
  - Another session building in the same folder can make a build fail. Wait
    and rebuild rather than install a stale app.
  - Build from the working tree, not from a cleaned-up export. An export
    signs ad hoc, which breaks iCloud and passwords.
- iPhone: build with `xcodebuild` and the App Store Connect key, then install
  with `xcrun devicectl device install app`.

## Testing and verifying

- Shared code: `swift test` in `packages/EdenCore`.
- Mac: targeted `swift test --filter …` runs in `apps/macos`.
- iOS: `apps/ios/scripts/test.sh "<simulator>"`. The device is the first
  argument; a `DEVICE=` variable is ignored.
- UI tests on a real iPhone: `apps/ios/scripts/test-device.sh <udid>`.
- Don't run the full Mac suite and simulator UI runs at the same time:
  together they overload the Mac.
- Check visual changes in a live window, not only an offscreen render. Some
  effects, such as blend modes inside Liquid Glass, only fail live.
- Say plainly what wasn't checked on real devices, and which failures
  already existed before your change.

## Debugging

- In zsh, use `/usr/bin/log`, not `log`, which is a shell builtin.
- Eden's sync logs are under the subsystem `com.subhajit.eden.beta`.
- iPhone logs need a cable and `sudo log collect`.

## Signing

- Eden is signed with the Techaboard team (`HMJX9736KN`) using automatic
  signing. iOS and macOS share the bundle ID `com.subhajit.eden.beta`.
