# To do

What is left from the rebrand to Eden, and what has to exist before a
build goes to anyone else. Each item names where it is in the code.

## Before a public release

- [ ] **Developer ID certificate** A Developer ID Application certificate
  for Techaboard (team `HMJX9736KN`), in the login keychain of the Mac that
  ships. An Admin can make it under Certificates, Identifiers & Profiles
  once the Account Holder has given Admins access to Developer ID
  certificates; otherwise the Account Holder makes it. build.sh finds it on its own
  (`EDEN_SIGN_IDENTITY` names one). Until then builds are ad-hoc signed.
- [ ] **Notarization** `xcrun notarytool store-credentials "eden"` with an
  Apple ID of the team, for `./build.sh release ship`.
- [ ] **Passkeys entitlement** Ask Apple for
  `com.apple.developer.web-browser.public-key-credential` for
  `com.subhajit.eden.beta`, then a Developer ID provisioning profile that
  carries it, saved as `Eden.provisionprofile` next to apps/macos/build.sh
  (git-ignored). Without it the app is signed with `Eden.entitlements`
  and passkeys aren't offered.
- [x] **App ID** `com.subhajit.eden.beta` registered under the team, with
  the iCloud container `iCloud.com.subhajit.eden.beta`, by the iOS app's
  automatic signing (18 November 2026). Its development profile covers the
  team's devices.
- [ ] **The AI engine's App ID** `com.subhajit.eden.beta.ai-engine`, when
  the AI add-on ships (apps/macos/engine.sh signs it).
- [ ] **The iOS default-browser entitlement** Ask Apple for
  `com.apple.developer.web-browser` for `com.subhajit.eden.beta`, so Eden
  can be the default browser on iPhone and iPad. The app now meets what
  Apple asks (an address field and search at launch, http and https
  declared, no UIWebView); the request needs the Account Holder. Then add
  the entitlement to apps/ios/Configuration/Eden.entitlements.
- [ ] **A physical iPhone or iPad** on the same Apple Account as the Mac,
  for Handoff (Phase 1): Simulator can't hand off.

## Updates (off)

- [ ] **A signed feed of Eden's own** Host what `./build.sh release ship`
  makes (`appcast.json`, `appcast.json.zip`, `Eden.zip`, `Eden.dmg`, and
  `intel/` for the Intel build) at `Brand.updateFeed`
  (apps/macos/Sources/Eden/Brand.swift), with `EDEN_DOWNLOAD_URL` pointing at the same
  folder. `./publish.sh <folder>` copies them.
- [ ] **Turn updates on** `Brand.updatesEnabled = true`. That brings back
  Check for Updates… in the Eden menu and the Updates rows in Settings, and
  the AI add-on's engine, which arrives through the same feed.

## Brand

- [ ] **A designed mark** The icon and the logomark are the pill Search
  cut its S from, with an E (apps/macos/Icon/icon.swift, `Logomark` in
  apps/macos/Sources/Eden/Design.swift and apps/ios/Sources/Logomark.swift).
  `apps/ios/scripts/make-icon.sh` writes the iOS icon from the same script.
- [ ] **A site** `Brand.website`, the download link in README.md, and
  `Brand.aiCallback` (OpenRouter's sign-in, never loaded) move to Eden's
  own domain.
- [ ] **A feedback mailbox** `Brand.feedbackEmail`: Found something wrong?
  opens a draft with no recipient until there is one.
- [ ] **A screenshot** for README.md.
- [ ] **Homebrew** A cask, once there are releases to point it at.

## Known test failures

Both were already failing in Search, the code Eden began as, and fail the
same way before and after the move to EdenCore.

- [ ] **History regressions** `packages/EdenCore/Tests/HistoryRegression/run.sh`
  fails 10 assertions about merging older history records and keeping a
  site's front door (for example "a titled front door should never move").
- [ ] **Pointer-driven sidebar tests** 4 tests in `PinDragTests` and
  `SidebarPressTests` (apps/macos) fail with 8 assertions. Others in those
  suites fail too if the pointer is used while they run.
