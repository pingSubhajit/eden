# Shared packages

Code both apps build.

## EdenCore

What Eden for the Mac (`apps/macos`) and Eden for iPhone and iPad
(`apps/ios`) share, as a Swift package for macOS 14 and iOS 27 with no
AppKit or UIKit in it: each app draws its own.

| | |
|---|---|
| `Store`, `Disk` | Where everything is kept, a test run's world apart from yours, and files written in the background, newest last |
| `Address`, `Engine`, `Keyword`, `Fuzzy`, `Registrable` | What was typed in the address field: an address or words, which engine, a site's shortcut, a slip forgiven, a site's registrable name |
| `History`, `Suggestion` | Where you have been, and the rows under the address field |
| `Shield`, `YouTubeRules` | The blocker's rules, compiled for WebKit, and YouTube's ad requests |
| `Bookmark`, `Space`, `PinDef`, `SyncMerge` | The data that syncs, and the merge that decides what wins |
| `Continuity` | Eden's Handoff activity, and which pages may go between devices |

The Mac app depends on it in `apps/macos/Package.swift`; the iOS project
links it as a local package (`apps/ios/scripts/generate-project.py`). Its
own tests run with `swift test` here.

What stays in each app: drawing, menus and commands (the Mac's
`AddressCommand` travels in a `Suggestion` as a `Suggestion.Command` it
writes and reads), engine suggestions and the proxy they go through, and
the scripts that skip YouTube's ads.
