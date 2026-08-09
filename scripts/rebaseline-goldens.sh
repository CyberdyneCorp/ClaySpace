#!/usr/bin/env bash
# Regenerate the brush verification reference images.
#
#   scripts/rebaseline-goldens.sh              simulator baseline
#   scripts/rebaseline-goldens.sh --device     connected iPad baseline
#
# Baselines are per device class, so each one you care about needs its own
# run: a simulator reference cannot stand in for an iPad's.
#
# A normal test run can never write these. The test bundle emits the new
# images as attachments and this script lifts them out of the .xcresult
# into the fixtures directory, so a baseline change always arrives as a
# reviewable diff rather than a silent overwrite.
set -euo pipefail
cd "$(dirname "$0")/.."

GOLDENS="app/Tests/ClaySpaceTests/Goldens"
SIM_NAME="${CLAY_SIM_NAME:-iPad Pro 11-inch (M4)}"
RESULT="$(mktemp -d)/rebaseline.xcresult"

xcodegen generate --spec app/project.yml --project app >/dev/null

if [ "${1:-}" = "--device" ]; then
    udid=$(xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null \
        | python3 -c '
import json, sys
data = json.load(sys.stdin)
for dev in data.get("result", {}).get("devices", []):
    hw = dev.get("hardwareProperties", {})
    if "iPad" in hw.get("marketingName", "") and hw.get("udid"):
        if dev.get("connectionProperties", {}).get("tunnelState") == "connected":
            print(hw["udid"])
            break
')
    if [ -z "$udid" ]; then
        echo "error: no connected iPad found" >&2
        exit 1
    fi
    echo "==> Re-baselining on device $udid"
    DESTINATION="platform=iOS,id=$udid"
    EXTRA=(-allowProvisioningUpdates)
else
    echo "==> Re-baselining on simulator: $SIM_NAME"
    DESTINATION="platform=iOS Simulator,name=$SIM_NAME"
    EXTRA=(CODE_SIGNING_ALLOWED=NO)
fi

# CLAY_GOLDEN_REBASELINE makes the bundle EMIT references instead of
# comparing; without it the same run compares and fails on drift.
xcodebuild test \
    -project app/ClaySpace.xcodeproj -scheme ClaySpace \
    -destination "$DESTINATION" \
    -only-testing:ClaySpaceTests/BrushMatrixTests \
    -resultBundlePath "$RESULT" \
    TEST_RUNNER_CLAY_GOLDEN_REBASELINE=1 \
    "${EXTRA[@]}" >/dev/null

WORK="$(mktemp -d)"
xcrun xcresulttool export attachments --path "$RESULT" --output-path "$WORK" >/dev/null

mkdir -p "$GOLDENS"
python3 - "$WORK" "$GOLDENS" <<'EOF'
import json, os, shutil, sys
work, goldens = sys.argv[1], sys.argv[2]
manifest = json.load(open(os.path.join(work, "manifest.json")))
written = 0
for test in manifest:
    for attachment in test.get("attachments", []):
        name = attachment.get("suggestedHumanReadableName") or ""
        # Attachment names are suffixed with an index and a uuid; the
        # reference name is the part before the first underscore.
        stem = name.split("_")[0]
        if not stem.startswith("golden-"):
            continue
        source = os.path.join(work, attachment.get("exportedFileName", ""))
        if not os.path.exists(source):
            continue
        shutil.copy(source, os.path.join(goldens, stem + ".png"))
        written += 1
print(f"wrote {written} reference images to {goldens}")
EOF

echo "==> Review the diff before committing: git status $GOLDENS"
