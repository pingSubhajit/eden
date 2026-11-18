#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/eden-history-regression.XXXXXX")
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

swiftc \
  -parse-as-library \
  -swift-version 5 \
  "$repo_root/Sources/EdenCore/Address.swift" \
  "$repo_root/Sources/EdenCore/History.swift" \
  "$repo_root/Sources/EdenCore/Suggestion.swift" \
  "$repo_root/Sources/EdenCore/Fuzzy.swift" \
  "$repo_root/Tests/HistoryRegression/Stubs.swift" \
  "$repo_root/Tests/HistoryRegression/main.swift" \
  -o "$test_root/history-regression"

EDEN_HISTORY_TEST_ROOT="$test_root/store" "$test_root/history-regression"
