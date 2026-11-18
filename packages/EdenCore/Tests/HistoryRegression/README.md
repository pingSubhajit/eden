# History URL identity regression runner

Run `packages/EdenCore/Tests/HistoryRegression/run.sh` from any directory. It
compiles EdenCore's real `Address.swift`, `History.swift` and `Suggestion.swift`
with only small framework and storage stubs. The runner creates a fresh temporary store and removes it when
finished; it never reads or writes the browser's normal history file.
