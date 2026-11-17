# Roadmap

What is being built, what comes next, and what is not planned. What has
shipped is in [CHANGELOG.md](CHANGELOG.md); what is left from the rebrand
is in [TODO.md](TODO.md).

## Being built

- **Rebrand to Eden** Search, renamed and signed by Techaboard. Done in
  0.1.0; the open ends are in TODO.md.

## Next: Eden on iPhone and iPad

A companion app for iOS and iPadOS, and the tabs moving between it and
the Mac.

1. **Handoff from the Mac** *Built, off unless turned on.* The page in
   front is offered to your other devices (`NSUserActivity`), and a page
   handed off from them opens in Eden. Eden for iPhone and iPad takes it,
   and offers the page it shows back.
2. **A shared core** The parts that aren't the Mac's alone — the session,
   pins, the sync merge, the blocker's rules, hidden elements, reading
   mode — in a Swift package both apps build.
3. **Eden for iOS and iPadOS** Tabs, the address field, pins and spaces,
   private tabs, reading mode, the blocker and hidden elements, bookmarks
   and history, on the shared core. Same bundle id as the Mac
   (`com.subhajit.eden.beta`), so Handoff and iCloud work between them.
4. **Your tabs on every device** Open tabs from your other devices, and
   the pins, bookmarks and spaces sync extended to iOS, through CloudKit
   under the existing merge (SyncMerge.swift).

## Not planned

- **Windows and Linux** Eden is made of the Mac's own WebKit and AppKit.
- **macOS before 14** The app leans on what macOS 14 added to WebKit.
