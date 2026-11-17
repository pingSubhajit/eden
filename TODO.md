# To do

What is left from the rebrand to Eden, and what has to exist before a
build goes to anyone else. Each item names where it is in the code.

## Before a public release

- [ ] **Developer ID certificate** A Developer ID Application certificate
  for Techaboard (team `HMJX9736KN`), made by the account holder, in the
  login keychain of the Mac that ships. build.sh finds it on its own
  (`EDEN_SIGN_IDENTITY` names one). Until then builds are ad-hoc signed.
- [ ] **Notarization** `xcrun notarytool store-credentials "eden"` with an
  Apple ID of the team, for `./build.sh release ship`.
- [ ] **Passkeys entitlement** Ask Apple for
  `com.apple.developer.web-browser.public-key-credential` for
  `com.subhajit.eden.beta`, then a Developer ID provisioning profile that
  carries it, saved as `Eden.provisionprofile` next to build.sh
  (git-ignored). Without it the app is signed with `Eden.entitlements`
  and passkeys aren't offered.
- [ ] **App ID** Register `com.subhajit.eden.beta` (and
  `com.subhajit.eden.beta.ai-engine`) under the team, shared with the iOS
  app to come.

## Updates (off)

- [ ] **A signed feed of Eden's own** Host what `./build.sh release ship`
  makes (`appcast.json`, `appcast.json.zip`, `Eden.zip`, `Eden.dmg`, and
  `intel/` for the Intel build) at `Brand.updateFeed`
  (Sources/Eden/Brand.swift), with `EDEN_DOWNLOAD_URL` pointing at the same
  folder. `./publish.sh <folder>` copies them.
- [ ] **Turn updates on** `Brand.updatesEnabled = true`. That brings back
  Check for Updates… in the Eden menu and the Updates rows in Settings, and
  the AI add-on's engine, which arrives through the same feed.

## Brand

- [ ] **A designed mark** The icon and the logomark are the pill Search
  cut its S from, with an E (Icon/icon.swift, `Logomark` in
  Sources/Eden/Design.swift). Both draw the same path.
- [ ] **A site** `Brand.website`, the download link in README.md, and
  `Brand.aiCallback` (OpenRouter's sign-in, never loaded) move to Eden's
  own domain.
- [ ] **A feedback mailbox** `Brand.feedbackEmail`: Found something wrong?
  opens a draft with no recipient until there is one.
- [ ] **A screenshot** for README.md.
- [ ] **Homebrew** A cask, once there are releases to point it at.
