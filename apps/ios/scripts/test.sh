#!/bin/bash
# Runs the iOS app's unit and UI tests on a simulator, with the pages some UI
# tests load served from this Mac (UITests/Fixtures, over http: WebKit's
# content rules, which the blocker is, don't apply to data: pages). The
# simulator reaches the Mac's localhost; the test is told where through
# TEST_RUNNER_EDEN_FIXTURES, and skips itself without it.
#
#   apps/ios/scripts/test.sh                  on "Eden iPhone 17 Pro"
#   apps/ios/scripts/test.sh "Eden iPad Pro"  on another simulator
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${1:-Eden iPhone 17 Pro}"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory UITests/Fixtures > /dev/null 2>&1 &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null || true' EXIT
TEST_RUNNER_EDEN_FIXTURES="http://localhost:$PORT" xcodebuild -project Eden.xcodeproj -scheme Eden \
  -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath .build/xcode test
