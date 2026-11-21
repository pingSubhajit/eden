![Eden](.github/assets/banner.jpg)

# Eden

An opinionated web browser for the Mac, iPhone and iPad, with your tabs on all three.

Eden picks one way to do each thing and leaves the screen to a column of tabs, one field and the page. It runs on WebKit, the engine already in macOS and iOS, so the Mac app weighs about 12 MB.

macOS 14 or later · iOS and iPadOS 27 or later · free. No public download yet, so [build it yourself](#building-it).

## Across your devices

Eden keeps your Mac, iPhone and iPad in step through your own iCloud. It syncs your open tabs, history, spaces, pins and settings, and the iPhone and iPad's bookmarks. On the Mac, pins are where you keep pages, and ⌘D pins the page in front.

- **Your other devices' tabs, beside your own.** On the Mac, each device gets a group in the column, under your pins, listing what it has open in the space you're in. On iPhone and iPad they sit in the tab overview and the sidebar.
- **Carry on where you stopped.** Open a page from another device and Eden puts it in the space it came from, scrolled to where you were, in reading mode if you were reading. If the page is open here already, Eden switches to it.
- **Send a tab, or close one.** Drag a tab onto a device's group to open it there, behind the page in front. Click the cross beside another device's tab to close it there. The device acts on both at its next sync.
- **Pick up on iPhone.** A new tab offers the page you were just reading on your Mac and the pages you closed there in the last ten minutes. The field suggests pages open on your other devices as you type.
- **One set of pins.** A page pinned on your Mac and your iPhone becomes one pin on each device, its tab and history with it.
- **Handoff.** Turn it on in Settings › General to pass the page in front to a nearby device, in Eden or its browser.

## On each device

- **A column of tabs.** Pin the pages you keep open all day. Gather tabs into groups, give each a colour and an icon, and fold a group when you don't need it. Rest the pointer on a tab to see its page.
- **Spaces and profiles.** A space holds its own tabs, pins and groups. A profile adds its own cookies, sign-ins and history.
- **iPhone and iPad.** The iPhone keeps the field at the bottom and your tabs in a deck of cards, a room for each space. The iPad lists them down a sidebar.
- **A blocker that runs first.** WebKit stops trackers and ad networks before it makes the request. Turn it off for a site that breaks.
- **Hide what you don't want.** Press ⇧⌘H and click a cookie banner or an overlay. Eden hides it on that site from then on, before the page draws.
- **Extensions.** Paste an extension's store link in Settings › Extensions. Eden runs it on WebKit's extension engine and adds the APIs WebKit lacks. Needs macOS 15.4.

## Privacy

Eden has no account, no server and no telemetry.

| What | Where it lives | Synced |
|---|---|---|
| Passwords | The macOS keychain, as items tagged `Eden` | No |
| Tabs, bookmarks, history, spaces, pins, settings | `~/Library/Application Support/Eden/` | To your private CloudKit database |
| Hidden elements, page pictures | `~/Library/Application Support/Eden/` | No |
| Session cookies kept for a restart | The same folder, sealed with a key in the keychain | No |
| Cookies and site data | WebKit's store | No |
| Extensions | `~/Library/Application Support/Eden/Extensions/` and WebKit's extension store | No |

What leaves the device: the pages you open and their icons, what syncs to your iCloud, and, with Handoff on, the address and title of the page in front. Two settings, both off at first, change that. Search suggestions send what you type to your search engine, and a proxy carries everything Eden fetches.

A private tab (⇧⌘N) has its own cookies, keeps nothing when it closes, and stays out of sync and Handoff.

Apps you allow in System Settings › Privacy & Security › Automation can read your tabs' addresses and titles with AppleScript. They can't see private tabs.

## Keyboard

| | |
|---|---|
| ⌘T new tab or find a tab | ⌘L the field |
| ⌘W close tab | ⇧⌘T reopen it |
| ⌘N new window | ⇧⌘N private tab |
| ⌥⌘T new tab in group | ⌃⌘N new group |
| ⇧⌘[ ⇧⌘] previous, next tab | ⌘1 to ⌘9 jump to a tab |
| ⌃Tab recent tabs | ⌘S hide the column |
| ⇧⌘H hide something | ⌘D pin or unpin the page |
| ⌘Y history | ⇧⌘J downloads |

Change any of them in Settings › Keyboard & Mouse › Shortcuts.

## For developers

The code is yours to read, build and change: about 136,000 lines of Swift, with nothing outside what Apple ships.

### Where things are

| | |
|---|---|
| `apps/macos/` | The Mac app: its Swift package, `build.sh`, tests and `bench` |
| `apps/ios/` | The iPhone and iPad app, an Xcode project. See its README. |
| `packages/EdenCore/` | What both apps share: storage, the field's sense of what you typed, history, the blocker's rules, spaces, sync. See `packages/README.md`. |
| `VERSION` | The version both apps carry |

### Building it

You need Xcode 27. From `apps/macos/`:

- `swift build` runs the app from SwiftPM.
- `./build.sh` makes `build/Eden.app`. It signs with a Developer ID or development certificate from your keychain if it finds one, and ad hoc otherwise.
- `EDEN_DEV=1 ./build.sh` makes a dev build with a yellow icon, named after its branch.
- `./build.sh release dmg` adds `Eden.dmg` and `Eden.zip`. `./build.sh release ship` also notarizes, which needs the owner's Apple credentials.

An ad hoc build asks for a right-click › Open on first launch. Its passwords stay apart from a signed Eden's, since the keychain tells the two apps apart by signature.

### How it's put together

- SwiftUI draws the app, AppKit and UIKit cover what SwiftUI can't reach, and WKWebView shows pages.
- Each page gets one `Tab`. Eden builds its web view the first time you look at it, so twenty restored tabs cost nothing at launch.
- The blocker is a `WKContentRuleList` that Eden compiles once. WebKit enforces it in its networking.
- Hidden elements are a stylesheet of selectors that Eden injects at document start.
- `Design.swift` holds every colour as a light and dark pair.
- Extensions run on `WKWebExtension`. `Crx.swift` checks a package's signature before unpacking it, and `ExtensionShims.swift` adds the APIs WebKit lacks.
- `apps/macos/Sources/Eden/` has one file per concern: `Vault.swift` for the keychain, `Shield.swift` for the blocker, `Session.swift` for what comes back at launch.

### Testing it

- Shared code: `swift test` in `packages/EdenCore`.
- Mac: `swift test --filter …` in `apps/macos`.
- iPhone and iPad: `apps/ios/scripts/test.sh "<simulator>"`.

To drive a running Eden, turn on Settings › General › Let a script drive Eden and use `./bench` from `apps/macos`:

```
./bench open https://example.com     # a tab of its own, marked with a flask
./bench wait 2e7e7e89                 # until it loads
./bench text 2e7e7e89                 # the page's text
./bench shot 2e7e7e89 out.png         # a picture of it
./bench click 2e7e7e89 "button.go"    # through the page's own events
./bench close all
```

Bench tabs stay out of your session and history. `./bench-mcp` serves the same commands to a coding agent as an MCP server. It starts this checkout's build hidden, in a test world it wipes when the session ends.

### Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) first. Keep changes small, add no dependencies, and send nothing home. Report security problems privately, as [SECURITY.md](SECURITY.md) describes.

### License

MIT. See [LICENSE](LICENSE). Copyright © 2026 Subhajit Kundu, who also owns the name "Eden" and its icon. Rename a fork before you distribute it.
