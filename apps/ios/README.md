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
| Handoff | `NSUserActivityTypeBrowsingWeb` and `com.subhajit.eden.beta.browsing` |

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

Signing settings live in `Configuration/Base.xcconfig`. A
`Configuration/Local.xcconfig` (git-ignored) overrides them on one Mac.

## The icon

`Resources/AppIcon.icon` is an Icon Composer document written by the Mac
app's icon script, so both apps draw the one mark. After the mark changes:

    apps/ios/scripts/make-icon.sh
