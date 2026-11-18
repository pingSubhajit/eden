#!/bin/bash
# Runs UI tests on a real iPhone or iPad joined to this Mac by cable, with the
# pages they load served on the Mac's local network address (the device
# can't reach the Mac's localhost). Eden asks once for local network access;
# the tests allow it. The device must be unlocked.
#
# Signing the test runner for the device needs an Xcode account, or an App
# Store Connect API key: EDEN_ASC_KEY (the .p8), EDEN_ASC_KEY_ID and
# EDEN_ASC_ISSUER.
#
#   apps/ios/scripts/test-device.sh <udid> [xcodebuild options…]
#   apps/ios/scripts/test-device.sh 00008150-… -only-testing:EdenUITests/EdenUITests/testX
set -euo pipefail
cd "$(dirname "$0")/.."
DEVICE="${1:?usage: test-device.sh <udid> [xcodebuild options…]}"
shift
ADDRESS="$(ipconfig getifaddr en0 || ipconfig getifaddr en1)"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("0.0.0.0", 0)); print(s.getsockname()[1]); s.close()')"
LOG="$(mktemp -t eden-fixtures)"
python3 -m http.server "$PORT" --bind "$ADDRESS" --directory UITests/Fixtures > "$LOG" 2>&1 &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null || true' EXIT
# Serving before the tests start, or saying why not.
for _ in $(seq 1 50); do curl -s -o /dev/null "http://$ADDRESS:$PORT/page-one.html" && break; sleep 0.1; done
curl -s -o /dev/null "http://$ADDRESS:$PORT/page-one.html" || { echo "The pages wouldn't serve:" >&2; cat "$LOG" >&2; exit 1; }
SIGNING=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration)
if [[ -n "${EDEN_ASC_KEY:-}" ]]; then
  SIGNING+=(-authenticationKeyPath "$EDEN_ASC_KEY" -authenticationKeyID "$EDEN_ASC_KEY_ID"
            -authenticationKeyIssuerID "$EDEN_ASC_ISSUER")
fi
TEST_RUNNER_EDEN_FIXTURES="http://$ADDRESS:$PORT" xcodebuild -project Eden.xcodeproj -scheme Eden \
  -destination "id=$DEVICE" -derivedDataPath .build/xcode-device "${SIGNING[@]}" test "$@"
