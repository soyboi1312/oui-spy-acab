#!/usr/bin/env bash
# ACAB release orchestrator: preflight -> tests -> build-and-stage -> verify -> STOP.
#
# WHAT THIS IS FOR. Cutting a release touches two repositories, two staging scripts, three test
# suites and a verifier, and the order matters. Doing it by hand is how 2.0.3 shipped with stale
# artifacts and how the 2.0.4 firmware version nearly shipped un-bumped. This script makes the
# sequence one command and refuses to continue when a precondition is not met.
#
# WHAT IT DELIBERATELY DOES NOT DO: publish. It stops after verification and prints both repos'
# status for a human to review. Tagging, pushing and releasing stay manual, on purpose - they are
# the irreversible steps.
#
# INTERIM SEQUENCE, and why it is not the ideal one. web/build-flasher.sh and
# ../soyboi.tech/firmware/build-beacon-flasher.sh each run `pio` themselves. Rev-B is the one
# deliberate additional build because the sibling stager knows only rev-A. The right end state is
#   build once -> stage from the build dir -> verify a temp release dir -> promote (atomic move)
# which needs both stagers refactored. Until then the order below is the correct one for the
# scripts as they actually exist.
#
# Ordinary iteration is untouched: `pio run`, USB flashing and the bench flow do not go through
# here. This gates RELEASES, not development.
#
#   ./release.sh --profile beacon              # the dual-radio board
#   ./release.sh --profile colonel-panic       # oui-spy + mesh-detect
#   ./release.sh --profile all --with-apps     # everything, including the phone test suites
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "$0")"
cd "$SCRIPT_DIR"
REPO="$(cd ../.. && pwd)"
SITE="$(cd "$REPO/../soyboi.tech" 2>/dev/null && pwd || true)"

PROFILE=""
ALLOW_DIRTY=0
WITH_APPS=0
UNSIGNED_USB_ONLY=0

die() { echo "!! $*" >&2; exit 1; }
step() { echo; echo "=== $* ==="; }

while [ $# -gt 0 ]; do
    case "$1" in
        --profile) PROFILE="${2:-}"; shift 2 ;;
        --allow-dirty) ALLOW_DIRTY=1; shift ;;
        --with-apps) WITH_APPS=1; shift ;;
        --unsigned-usb-only) UNSIGNED_USB_ONLY=1; shift ;;
        -h|--help) sed -n '2,24p' "$SCRIPT_PATH"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

# Named PROFILES rather than a free-form target list: the two staging scripts have fixed target
# sets baked in, so a free-form list would imply a granularity that does not exist.
case "$PROFILE" in
    beacon|colonel-panic|all) ;;
    "") die "--profile is required (beacon | colonel-panic | all)" ;;
    *)  die "unknown profile '$PROFILE' (beacon | colonel-panic | all)" ;;
esac

# ---------------------------------------------------------------------------
step "1/5 preflight"
# ---------------------------------------------------------------------------
# A dirty tree means the commit SHA does not identify the bytes being shipped. The digest covers
# Git's full binary patch plus the exact path, type, mode, and bytes of every untracked file. It is
# deliberately independent of whether the final bytes happen to be staged.
digest="$(python3 ./dirty-tree-provenance.py "$REPO" --short 12)"
if [ "$digest" != "clean" ]; then
    if [ "$ALLOW_DIRTY" -eq 0 ]; then
        git -C "$REPO" status --porcelain
        die "working tree is dirty. Commit, or re-run with --allow-dirty (provenance will record a digest)."
    fi
    echo "   dirty tree ALLOWED; provenance digest ${digest}"
    git -C "$REPO" status --porcelain
fi

# The site repo is not optional for the beacon profile: silently skipping it is how a release ships
# with the phone-facing OTA manifest still pointing at the previous version.
if [ "$PROFILE" = "beacon" ] || [ "$PROFILE" = "all" ]; then
    [ -n "$SITE" ] || die "../soyboi.tech not found; the beacon profile stages its OTA artifacts there"
    [ -f "$SITE/firmware/build-beacon-flasher.sh" ] || die "$SITE/firmware/build-beacon-flasher.sh missing"
    # This repository owns the rev-B staging implementation, but the sibling owns its HTML. The
    # contract check runs before any stager writes there and refuses the rev-A page as a fallback.
    python3 ./stage_beacon_revb.py --firmware-dir "$REPO/firmware" --site-dir "$SITE" --check-contract
fi

# An unsigned OTA image is one the board will refuse in the field, so a signing key that is missing
# has to stop the run unless the operator is explicitly cutting a USB-only build. All profiles use
# this key: web/build-flasher.sh signs the OUI-Spy and Mesh images as well as the beacon stager.
KEY="$REPO/firmware/tools/ota_signing/beacon_ota_key.pem"
if [ ! -f "$KEY" ] && [ "$UNSIGNED_USB_ONLY" -eq 0 ]; then
    die "OTA signing key not found at ${KEY#$REPO/}. Re-run with --unsigned-usb-only for a flasher-only build."
fi
if [ "$UNSIGNED_USB_ONLY" -eq 1 ]; then
    SIGNED_LABEL="NO (explicit USB-only cut)"
elif [ -f "$KEY" ]; then
    SIGNED_LABEL="yes"
else
    SIGNED_LABEL="NO"
fi
echo "   profile=$PROFILE apps=$WITH_APPS signed=$SIGNED_LABEL"

# ---------------------------------------------------------------------------
step "2/5 tests"
# ---------------------------------------------------------------------------
./host-tests/run.sh
python3 ./check-signature-drift.py   # signatures.md must still describe the shipped tables
# The release-tooling suite gates the very scripts the steps below run. Sibling-dependent case
# skips itself when soyboi.tech is absent.
python3 -m unittest discover -s tests -p 'test_*.py'

if [ "$WITH_APPS" -eq 1 ]; then
    # --rerun-tasks is MANDATORY, not tidiness: a bare `gradlew test` reports UP-TO-DATE and runs
    # ZERO tests, which looks identical to a green suite in the log.
    ( cd "$REPO/android" && ./gradlew testDebugUnitTest --rerun-tasks )
    # `test`, not `build`: the app target compiles fine without the test target, so building the
    # app proves nothing about the tests. The Xcode project is generated and ignored, so a clean
    # checkout must regenerate it before invoking xcodebuild.
    command -v xcodegen >/dev/null 2>&1 || die "xcodegen is required for --with-apps"
    ( cd "$REPO/ios" && xcodegen generate && \
      xcodebuild -project Beacons.xcodeproj -scheme Beacons -sdk iphonesimulator \
        -destination 'platform=iOS Simulator,name=iPhone 17' test )
fi

# ---------------------------------------------------------------------------
step "3/5 build and stage"
# ---------------------------------------------------------------------------
# The existing stagers build their own environments. Rev-B is built explicitly because the
# sibling stager cannot build or name it, and a distinct image is mandatory for its hardware.
if [ "$PROFILE" = "colonel-panic" ] || [ "$PROFILE" = "all" ]; then
    # Forward the unsigned opt-in: build-flasher.sh now fails closed on a missing signing key,
    # matching this script's own posture.
    if [ "$UNSIGNED_USB_ONLY" -eq 1 ]; then
        ( cd "$REPO/web" && ./build-flasher.sh --unsigned-usb-only )
    else
        ( cd "$REPO/web" && ./build-flasher.sh )
    fi
fi
if [ "$PROFILE" = "beacon" ] || [ "$PROFILE" = "all" ]; then
    ( cd "$REPO/firmware" && pio run -e beacon-board-revb )
    ( cd "$SITE/firmware" && ./build-beacon-flasher.sh )
    BOOT_APP0="$(find "$HOME/.platformio/packages/framework-arduinoespressif32/tools/partitions" \
        -name boot_app0.bin -print -quit 2>/dev/null)"
    [ -n "$BOOT_APP0" ] || die "boot_app0.bin not found after the rev-B build"
    REV_B_ARGS=(
        --firmware-dir "$REPO/firmware"
        --site-dir "$SITE"
        --boot-app0 "$BOOT_APP0"
    )
    if [ "$UNSIGNED_USB_ONLY" -eq 1 ]; then
        REV_B_ARGS+=(--unsigned-usb-only)
    else
        REV_B_ARGS+=(--signing-key "$KEY")
    fi
    python3 ./stage_beacon_revb.py "${REV_B_ARGS[@]}"
fi

# ---------------------------------------------------------------------------
step "4/5 verify"
# ---------------------------------------------------------------------------
# --production turns absence into failure and requires signatures to actually verify.
VERIFY_ARGS=(--production --profile "$PROFILE")
[ "$UNSIGNED_USB_ONLY" -eq 1 ] && VERIFY_ARGS+=(--usb-only)
python3 ./verify-release-artifacts.py "${VERIFY_ARGS[@]}"

# ---------------------------------------------------------------------------
step "5/5 review (publishing is a human action)"
# ---------------------------------------------------------------------------
echo "--- $REPO"
git -C "$REPO" status --short
echo "--- $SITE"
[ -n "$SITE" ] && git -C "$SITE" status --short || true
echo
echo "Verified. NOTHING has been committed, tagged, or published."
echo "Review both diffs, then tag and push by hand."
