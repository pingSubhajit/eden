# Eden for iPhone and iPad

The iOS and iPadOS app. Phase 0 of the roadmap: the app exists, signs as
Techaboard's, carries the iCloud container and opens a page handed off to
it. The browser comes in Phase 3, on the core it will share with the Mac
app (`packages/`).

| | |
|---|---|
| Bundle id | `com.subhajit.eden.beta`, the same as the Mac app |
| Team | `HMJX9736KN`, Techaboard Digi Solutions Private Limited |
| Signing | Automatic, as Mulberry's |
| iOS | 27.0 or later, iPhone and iPad |
| iCloud | CloudKit, container `iCloud.com.subhajit.eden.beta` |
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

The unit tests (Swift Testing, in `Tests/`) run inside the app on a
simulator:

    xcodebuild -project apps/ios/Eden.xcodeproj -scheme Eden \
      -destination 'platform=iOS Simulator,name=Eden iPhone 17 Pro' \
      -derivedDataPath apps/ios/.build/xcode test

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
