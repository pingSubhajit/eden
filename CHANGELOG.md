# Changelog

What changes in Eden from one version to the next, newest first.

**Unreleased** gathers what is done since the last version, as it lands:
every fix and every addition gets its line the day it is merged. When a
version ships, the section takes its number and date, and its gist becomes
the paragraph in `NOTES.md`. What is planned but not done yet lives in
[ROADMAP.md](ROADMAP.md).

Eden began as a fork of [Search](https://github.com/driceroland/Search) by
Office Commun at its version 1.0.13; what changed before that is in Search's
own changelog.

## Unreleased

- Hand off pages to your other devices, off until you turn it on in Settings › General: the page in front can be picked up on your iPhone, iPad or another Mac with Handoff, in Eden there or in its browser. Never a private tab's. A page handed over from another device, from Eden there or from Safari once Eden is your browser, opens in a tab here, whatever the switch says.
- Eden for iPhone and iPad is a browser: tabs and one field for addresses and searches, with suggestions from your tabs, bookmarks and history; private tabs; the Mac's ad and tracker blocker; bookmarks and history kept on the device; a choice of search engine. The field is at the bottom on iPhone, and the tabs down a sidebar on iPad. Handoff works both ways, offering the page in front once it is turned on in Settings.
- Brave's engine is called Brave Search again in the list of search engines.
- Sync with iCloud, on unless you turn it off in Settings: your open tabs, bookmarks, history, spaces, pins and settings, between your Macs, iPhone and iPad signed in to the same Apple Account, through your own private iCloud database. History › Tabs on Other Devices on the Mac, and On Your Other Devices in the iPhone's tabs and the iPad's sidebar, open what your other devices have open. It replaces syncing through a folder you choose. The iPhone and iPad sync the bookmarks (folders included), history, search engine and blocker, and carry the Mac's spaces and pins along untouched. It runs on Apple's CKSyncEngine, which schedules syncing, retries what didn't reach iCloud and wakes Eden when another device changes something; the Mac now also syncs as tabs open and close. What sync keeps on each device is a SQLite database, written only where it changed, so keeping it up to date takes about a millisecond for a replica of thousands of items, instead of rewriting a file of several megabytes.

## 0.1.0 — 18 November 2026

The first version of Eden.

- Renamed from Search: the app, its bundle (`com.subhajit.eden.beta`), its
  icon, its data folder (`~/Library/Application Support/Eden`), its keychain
  items, its AppleScript dictionary and its own pages (`eden://settings`).
- Signed with Techaboard's Developer ID (team `HMJX9736KN`).
- Updates are off until Eden has a signed feed of its own: no Check for
  Updates…, no Updates rows in Settings, nothing fetched (see TODO.md).
