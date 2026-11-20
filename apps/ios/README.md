# Eden for iPhone and iPad

The iOS and iPadOS browser, built on the code it shares with the Mac app
(`packages/EdenCore`):

- **Tabs and one field** for addresses and searches, with suggestions from
  your other open tabs, bookmarks and history. On iPhone the controls float
  at the bottom on glass, as Safari's do: back (stretching to hold forward
  once there is somewhere to go), the field with the page's menu at its
  start, and the tabs, a deck of cards like the iPhone's app switcher that
  the page zooms in and out of, a room for each space and one for private.
  Reading on down a page shrinks the controls to the site's name. The page
  runs up under the status bar, which reads dark or light by the page
  beneath it. On iPad the tabs run down a sidebar and the field is at the
  top.
- **Private tabs**, with a store of their own that keeps nothing, no history,
  and a dark bar so it's plain which kind is in front.
- **The Mac's blocker** (Shield and its YouTube rules), on unless turned off.
- **Bookmarks and history**, kept on the device; history is searchable and
  can be cleared. They sync with the Mac in Phase 4.
- **Settings:** the search engine, the blocker, and Handoff (off unless
  turned on, as on the Mac).
- **Handoff** both ways: a page handed over opens here, and with Handoff on,
  the page in front is offered to your other devices. Never a private tab.

The ordinary tabs come back at the next launch (`tabs.json`); private ones
never do. Everything is kept in the app's own folder (EdenCore's Store).

| | |
|---|---|
| Bundle id | `com.subhajit.eden.beta`, the same as the Mac app |
| Team | `HMJX9736KN`, the same as the Mac app |
| Signing | Automatic, as Mulberry's |
| iOS | 27.0 or later, iPhone and iPad |
| iCloud | CloudKit, container `iCloud.com.subhajit.eden.beta` |
| Shared code | `packages/EdenCore`, linked as a local package |
| Handoff | Takes `NSUserActivityTypeBrowsingWeb` and `com.subhajit.eden.beta.browsing`; offers the page it shows as the second |

## Building

The Xcode project is generated, never edited by hand, so it stays readable
in review. After adding or removing a source file:

    python3 apps/ios/scripts/generate-project.py

For the simulator, with no account needed:

    xcodebuild -project apps/ios/Eden.xcodeproj -scheme Eden \
      -destination 'generic/platform=iOS Simulator' -derivedDataPath apps/ios/.build/xcode build

For a device, signed with the team; `-allowProvisioningUpdates` lets Xcode
make or refresh the development profile:

    xcodebuild -project apps/ios/Eden.xcodeproj -scheme Eden \
      -destination 'generic/platform=iOS' -derivedDataPath apps/ios/.build/xcode \
      -allowProvisioningUpdates build

The unit tests (Swift Testing, in `Tests/`) and the UI tests (XCTest, in
`UITests/`, driving the app as a person would) run on a simulator:

    apps/ios/scripts/test.sh                      # "Eden iPhone 17 Pro"
    apps/ios/scripts/test.sh "Eden iPad Pro 13"   # the iPad's layout
    apps/ios/scripts/test.sh "Eden iPad Pro 13" -only-testing:EdenUITests/EdenUITests/testX

The device is the first argument; anything after it goes to `xcodebuild`.

The script serves `UITests/Fixtures` from this Mac, over http (the
blocker, WebKit's content rules, doesn't apply to a `data:` page), and the
UI tests load those pages and wait for their own words before going on: the
address field says where a tab is going before the page has arrived. Only
the search test reaches the network. The unit tests run in a test world of
their own (`EDEN_PROBE` in the scheme), and each UI test starts the app in
another with nothing in it (`EDEN_FRESH`), with a website store of its own
cleared before any page loads, so nothing of anyone's browsing is read or
written.

The UI tests also run on a real iPhone or iPad joined by cable, unlocked,
with the pages served on this Mac's local network address; Eden asks once
to reach it, and the tests allow it. Signing the test runner takes an
Xcode account, or an App Store Connect API key in `EDEN_ASC_KEY`,
`EDEN_ASC_KEY_ID` and `EDEN_ASC_ISSUER`:

    apps/ios/scripts/test-device.sh <udid> -only-testing:EdenUITests/EdenUITests/testX

On iPad, each UI step waits up to a minute for the app to look idle once a
page is showing: XCTest finds something still animating there, though Eden
itself sits at no CPU (measured). The run takes about 13 minutes instead of
3; the results are the same.

Signing settings live in `Configuration/Base.xcconfig`. A
`Configuration/Local.xcconfig` (git-ignored) overrides them on one Mac.

## Checking Handoff by hand

Handoff needs two real devices: Simulator can't hand off. Both signed in to
the same Apple Account, with Bluetooth and Wi-Fi on and Handoff on (System
Settings › General › AirDrop & Handoff on the Mac; Settings › General ›
AirPlay & Continuity on the iPhone). Both apps signed by the team: the
iPhone's development build, and a Mac build signed with the team's
certificate rather than ad-hoc (`EDEN_SIGN_IDENTITY` in apps/macos/build.sh).

1. On the Mac, turn on Settings › General › Hand off pages to your other
   devices, and open a page.
2. On the iPhone, open the app switcher: Eden's banner at the bottom offers
   the page. Tap it, and Eden opens on it.
3. Back on the Mac, Eden's icon at the left of the Dock (or in ⌘Tab) offers
   the page the iPhone shows. Click it, and it opens in a tab.

A private tab in front offers nothing, and nor does a page that isn't on
the web. The probe test `apps/macos/Tests/handoff.py` checks the Mac's half
without devices.

## The icon

`Resources/AppIcon.icon` is an Icon Composer document written by the Mac
app's icon script, so both apps draw the one mark. After the mark changes:

    apps/ios/scripts/make-icon.sh
