#!/bin/bash
# Writes Resources/AppIcon.icon, the iOS icon, with the Mac app's icon script,
# so both apps draw the one mark. Run after the mark changes.
set -euo pipefail
cd "$(dirname "$0")/.."
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
EDEN_ICON_SHARED=1 swift ../macos/Icon/icon.swift "$SCRATCH/iconset" "$SCRATCH/AppIcon.icon" > /dev/null
rm -rf Resources/AppIcon.icon
cp -R "$SCRATCH/AppIcon.icon" Resources/AppIcon.icon
echo "wrote: $(pwd)/Resources/AppIcon.icon"
