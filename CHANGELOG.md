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

- Spaces and pins on iPhone and iPad, as on the Mac, once Spaces is turned on in Settings: separate sets of tabs, each with its name, icon and colour, signed in where Personal is or with cookies and sign-ins of its own, switched from the tab overview on iPhone and the top of the sidebar on iPad. Pin a page from the menu: it stays at the head of its space, and on the start page; closing it rests it, back at its own page if Return Pins Home is on, and Go Home, Set Current Page as Home, Open as New Tab and Rename are in its menu. A pin can be shown in every space, each with a tab of its own for it. Spaces, pins and their settings sync with the Mac, and an iPhone or iPad that synced before takes over what the Mac had without changing any of it.
- On iPhone, the end of a page scrolls clear of the bar at the bottom, and what a page keeps at its foot — a cookie notice, say — sits above the bar rather than under it. Picking things to hide, the bar takes the address bar's place.
- On the Mac, a pinned row keeps its folder when another device renames or reorders it.
- Hide elements on iPhone and iPad: from the menu, tap what to take off a page, widen it to what holds it if the tap landed inside, and hide it — every time the site opens, as on the Mac, in the same list. A page's links stay put while you pick, and an embedded frame is offered whole. Hidden on This Site shows each thing on the page again before you restore it, and a change reaches every open tab on that site. A private tab's own changes, hiding or restoring, last only as long as it and the windows it opened, and are never kept.
- On the Mac, leaving a page while picking things to hide ends picking, and something the page took away while you pointed at it is never what gets hidden.
- Reading mode on iPhone and iPad: the article alone, in the device's light or dark, from the menu, and the page again on the next one. It is the Mac's reader, now shared, Markdown copies included once turned on in Settings; lead pictures are found on a phone's narrower pages too.
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
