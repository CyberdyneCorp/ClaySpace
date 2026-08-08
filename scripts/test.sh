#!/usr/bin/env bash
# ClaySpace test runner.
#
#   scripts/test.sh              run the suite on an iPad simulator
#   scripts/test.sh --device     run it on the first connected physical iPad
#                                (device unlocked, Developer Mode on)
#   scripts/test.sh --both       simulator first, then the device
#
# Unit/integration tests (engine, camera/input, ClayCore feature coverage:
# strokes, voxels, meshing, I/O, picking) run identically on both. The UI
# tap-to-sculpt test skips itself on hardware (the finger-tap shim is
# simulator-only; on device, fingers are strictly camera).
set -euo pipefail
cd "$(dirname "$0")/.."

SIM_NAME="${CLAY_SIM_NAME:-iPad Pro 11-inch (M4)}"

xcodegen generate --spec app/project.yml --project app >/dev/null

run_simulator() {
    echo "==> Testing on simulator: $SIM_NAME"
    xcodebuild test \
        -project app/ClaySpace.xcodeproj -scheme ClaySpace \
        -destination "platform=iOS Simulator,name=$SIM_NAME" \
        CODE_SIGNING_ALLOWED=NO
}

run_device() {
    local json udid name
    json=$(mktemp)
    xcrun devicectl list devices --json-output "$json" >/dev/null
    read -r udid name < <(python3 - "$json" <<'EOF'
import json, sys
data = json.load(open(sys.argv[1]))
for dev in data.get("result", {}).get("devices", []):
    hw = dev.get("hardwareProperties", {})
    state = dev.get("connectionProperties", {}).get("tunnelState", "")
    if "iPad" in hw.get("deviceType", "") or "iPad" in hw.get("marketingName", ""):
        # xcodebuild destinations take the hardware UDID; the devicectl
        # "identifier" is a different CoreDevice id it will not match.
        # NOTE: no apostrophes in here — the heredoc sits inside a process
        # substitution and bash gives up looking for the closing paren.
        if state == "connected" and hw.get("udid"):
            print(hw["udid"], hw.get("marketingName", "iPad").replace(" ", "_"))
            break
EOF
) || true
    rm -f "$json"
    if [ -z "${udid:-}" ]; then
        echo "error: no connected iPad found (check cable/Wi-Fi pairing and that the device is unlocked)" >&2
        exit 1
    fi
    echo "==> Testing on device: ${name:-iPad} ($udid)"
    xcodebuild test \
        -project app/ClaySpace.xcodeproj -scheme ClaySpace \
        -destination "platform=iOS,id=$udid" \
        -allowProvisioningUpdates
}

case "${1:-}" in
    --device) run_device ;;
    --both) run_simulator && run_device ;;
    *) run_simulator ;;
esac
