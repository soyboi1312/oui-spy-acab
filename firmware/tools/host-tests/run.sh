#!/usr/bin/env bash
# Host regression tests for the detection classifiers.
#
# WHY THIS EXISTS: the classifiers are pure functions over an advert buffer, so they can be tested
# on a laptop in under a second, with no board and no drive. That matters because a classifier
# regression COMPILES FINE and only shows up in the field as "it stopped detecting things" - which
# is the one failure this product cannot afford and the one you are least likely to notice.
#
# Added 2026-07-31 after glassesClassifyBLE was restructured from return-on-first-match to
# score-and-keep. That change was invisible to the compiler and to five rounds of code review.
#
#   ./run.sh          # build + run every test
set -euo pipefail
cd "$(dirname "$0")"
CORE="../../lib/acab_core"
fail=0
for t in test_*.cpp; do
    stem="${t#test_}"; stem="${stem%.cpp}"
    src="${CORE}/${stem}_detect.cpp"
    extra_flags=""
    if [ "$stem" = "det_log" ]; then
        # det_log is a full subsystem rather than a classifier, but the host flash,
        # Preferences, crypto, BLE, and FreeRTOS stubs let us compile its real source.
        src="${CORE}/det_log.cpp"
        extra_flags="-DACAB_HOST_TEST -pthread"
    fi
    if [ "$stem" = "link_action_lease" ]; then
        # Deterministically blocks a simulated disconnect boundary behind an in-flight physical
        # action callback, so the real check->action lease is exercised across two host threads.
        extra_flags="-pthread"
    fi
    if [ "$stem" = "coredump_report" ]; then
        # Compile the real IDF-facing state machine against deterministic esp_core_dump seams.
        src="${CORE}/coredump_report.cpp"
        extra_flags="-DACAB_HOST_TEST"
    fi
    if [ "$stem" = "alerts" ]; then
        # The test includes the real beacon-board alerts.cpp directly so it can exercise the
        # file-private tone helpers with host PWM/GPIO spies. Do not compile a second source copy.
        src=""
        extra_flags="-DACAB_HOST_TEST"
    elif [ ! -f "$src" ]; then
        # HEADER-ONLY SUITE. Not every testable unit is a classifier with a matching
        # <name>_detect.cpp: sink_claim.h is a pure decision extracted from acab_scanner.cpp
        # precisely so it can be tested without Arduino or FreeRTOS. Compile the test alone when
        # the unit under test is a header. Anything else is still a hard error - a typo'd suite
        # name silently compiling nothing is exactly the "the suite is smaller than I thought"
        # failure this script's header warns about.
        if [ -f "${CORE}/${stem}.h" ]; then
            src=""
        else
            echo "!! no source for $t (looked for $src and ${CORE}/${stem}.h)"; fail=1; continue
        fi
    fi
    echo ">> $t"
    # A COMPILE failure must be recorded and skipped, not fatal. Under `set -e` a bare g++ here
    # aborted the whole script on the first broken file, so the remaining tests never ran and the
    # log just stopped. That was survivable while this was one file run by hand; it is not now
    # that the suite has grown (ls test_*.cpp for the current count) and CI invokes this script,
    # where a truncated log reads as "the suite
    # is smaller than I thought" rather than "it died early". A failing test RUN already used
    # `|| fail=1` and continued, so this only makes the two paths behave the same way.
    g++ -std=c++17 -Wall ${extra_flags:+$extra_flags} -I"$CORE" -Istubs -o "/tmp/$(basename "$t" .cpp)" "$t" ${src:+"$src"} \
        || { echo "!! COMPILE FAILED: $t"; fail=1; continue; }
    "/tmp/$(basename "$t" .cpp)" || fail=1
done
exit $fail
