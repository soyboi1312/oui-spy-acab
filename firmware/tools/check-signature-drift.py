#!/usr/bin/env python3
"""Watch ACAB's one vendored dependency for upstream drift: the opendroneid decoder.
The Flock OUI table is own-sourced (own field captures plus Flock's IEEE block) and is
no longer diffed against any third-party curated list.

    python3 firmware/tools/check-signature-drift.py
    python3 firmware/tools/check-signature-drift.py --offline   # skip the network watch

Exits 0 when nothing upstream is missing locally, 1 when there is drift to look
at. It only reports; it never edits anything. Provenance is in CREDITS.md. When an
upstream repo moves a file or renames a branch, update the URLs below.

A network failure is NOT a pass here (see check_odid). Pass --offline to state on
purpose that a run is not watching upstream.
"""
import argparse
import glob
import hashlib
import json
import os
import re
import sys
import urllib.request

# --- upstream sources (edit as they move) -----------------------------------
LOCAL_FLOCK = "firmware/lib/acab_core/flock_detect.cpp"

# We no longer mirror any third-party curated Flock OUI list. The shipped Flock WiFi
# OUIs are our own field captures plus Flock's own IEEE block (see docs/signatures.md).
# This list stays empty on purpose: a curated upstream selection is not ours to track,
# and matching it was the source of the field false positives we since dropped.
UPSTREAM_FLOCK_URLS = []

# opendroneid decoder: watch for a NEW upstream RELEASE instead of byte-diffing
# master. core-c's last release is v2.0 (2022); everything on master since is
# unreleased const-correctness and encode-side churn we reviewed and chose to
# skip, so diffing master is pure noise. This flags only when core-c actually
# ships a newer release. Bump the baseline when you re-vendor opendroneid/.
ODID_REPO = "opendroneid/opendroneid-core-c"
ODID_BASELINE_RELEASE = "v2.0"   # latest release reviewed (2026-06-16)

# The real clamp every attacker-supplied advert name, SSID and ODID id passes through, plus the
# host tests that carry a link-stub copy of it (see check_ascii_clamp_copies).
LOCAL_ASCII_CLAMP = "firmware/lib/acab_core/acab_scanner.cpp"
HOST_TESTS_GLOB = "firmware/tools/host-tests/test_*.cpp"

# The two enums whose faqKey values ARE the keys of faq-content.json's relatedHelp map.
IOS_DEVICE_TYPE = "ios/Beacons/Models/DeviceType.swift"
AND_DEVICE_TYPE = "android/app/src/main/java/tech/acab/app/model/Models.kt"

# The app files carrying constants that must read the same on both platforms (see
# SHARED_CONSTANTS).
IOS_CONTRIBUTION_CSV = "ios/Beacons/BLE/ContributionCsv.swift"
IOS_BLE_MANAGER = "ios/Beacons/BLE/BLEManager.swift"
AND_BLE_MANAGER = "android/app/src/main/java/tech/acab/app/ble/AcabBleManager.kt"
IOS_SETTINGS = "ios/Beacons/Views/SettingsView.swift"
AND_DEVICE_SCREEN = "android/app/src/main/java/tech/acab/app/ui/DeviceScreen.kt"
CANONICAL_PRIVACY = "web/privacy.html"
CANONICAL_PRIVACY_URL = (
    "https://soyboi1312.github.io/all-cameras-are-beacons/privacy.html"
)
# ----------------------------------------------------------------------------

# A 3-byte OUI written as 0xNN,0xNN,0xNN (our C arrays) or NN:NN:NN (most lists).
# Lookarounds keep us from grabbing the first three bytes of a longer MAC.
OUI_CARR = re.compile(
    r"(?<![0-9A-Fa-f])0x([0-9A-Fa-f]{2})\s*,\s*0x([0-9A-Fa-f]{2})\s*,\s*0x([0-9A-Fa-f]{2})"
)
OUI_COLON = re.compile(
    r"(?<![0-9A-Fa-f:])([0-9A-Fa-f]{2}):([0-9A-Fa-f]{2}):([0-9A-Fa-f]{2})(?![0-9A-Fa-f:])"
)


def repo_root():
    return os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "acab-drift-check"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read().decode("utf-8", "replace")


def read_local(rel):
    with open(os.path.join(repo_root(), rel), encoding="utf-8") as f:
        return f.read()


def extract_ouis(text):
    out = set()
    for groups in OUI_CARR.findall(text):
        out.add("".join(g.upper() for g in groups))
    for groups in OUI_COLON.findall(text):
        out.add("".join(g.upper() for g in groups))
    return out


def fmt(oui):
    return f"{oui[0:2]}:{oui[2:4]}:{oui[4:6]}"


def check_flock(offline=False):
    print("== Flock OUI tables ==")
    local = extract_ouis(read_local(LOCAL_FLOCK))
    print(f"   local:    {len(local):>3} OUIs  ({LOCAL_FLOCK})")
    # Empty by CONFIGURATION, which is a real answer, unlike an empty result from failed fetches.
    # Those two used to collapse into the same "no third-party list is mirrored" line further
    # down, so the moment anyone re-added a URL a dead network would have read as no drift.
    if not UPSTREAM_FLOCK_URLS:
        print("   Flock OUIs are own-sourced; no third-party list is mirrored (see docs/signatures.md)")
        return 0
    if offline:
        print(f"   --   skipped (--offline): {len(UPSTREAM_FLOCK_URLS)} upstream list(s) not fetched")
        return 0
    upstream = set()
    unfetched = 0
    for url in UPSTREAM_FLOCK_URLS:
        try:
            found = extract_ouis(fetch(url))
            print(f"   upstream: {len(found):>3} OUIs  {url}")
            upstream |= found
        except Exception as exc:
            # A fetch that failed is a comparison that did not happen. Count it, or the run
            # reports "every upstream OUI is present locally" about a list it never read.
            print(f"   !! could not fetch {url}: {exc}")
            unfetched += 1
    missing = sorted(upstream - local)  # upstream has it, we don't -> drift risk
    extra = sorted(local - upstream)    # ours only -> additions from other sources
    if missing:
        print(f"\n   !! {len(missing)} upstream OUI(s) MISSING locally (possible drift):")
        for o in missing:
            print(f"      {fmt(o)}")
    elif unfetched == 0:
        print("   ok: every upstream OUI is present locally")
    if upstream:
        # Only meaningful against a list we actually read. With every fetch failed this would
        # report the entire local table as "superset additions", which is not what happened.
        print(f"   ({len(extra)} local-only OUIs, your superset additions)")
    return len(missing) + unfetched


def latest_release(repo):
    url = f"https://api.github.com/repos/{repo}/releases/latest"
    headers = {"User-Agent": "acab-drift-check", "Accept": "application/vnd.github+json"}
    # Unauthenticated api.github.com allows 60 requests/hour per SOURCE IP, and Actions runners
    # share egress IPs, so an unauthenticated call from CI hits a 403 fairly often. The workflow
    # hands us the job's own GITHUB_TOKEN, which raises that to the repo's own budget and removes
    # the usual reason this watch fails. Sent ONLY to api.github.com, never to fetch()'s
    # arbitrary upstream URLs.
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=20) as r:
        data = json.load(r)
    return data.get("tag_name"), (data.get("published_at") or "")[:10]


def check_odid(offline=False):
    print("\n== opendroneid decoder (release watch) ==")
    if offline:
        print(f"   --   skipped (--offline): {ODID_REPO} was not queried, so a new upstream")
        print("        release would not be seen by this run")
        return 0
    try:
        tag, date = latest_release(ODID_REPO)
    except Exception as exc:
        # NOT a pass. This request is the ONLY thing watching for a new core-c release, and
        # answering "nothing new to chase" about a question that was never asked is how an
        # upstream release goes unnoticed for a year while CI stays green. It used to WARN and
        # return 0, which is exactly that. Rate limits were the usual cause; GITHUB_TOKEN above
        # removes them, and --offline is the deliberate, visible opt-out.
        print(f"   !! could not query {ODID_REPO} releases: {exc}")
        print("      the release watch DID NOT RUN. Retry, set GITHUB_TOKEN, or pass --offline")
        print("      to record on purpose that this run is not watching upstream.")
        print("      (from a release cut: release.sh --offline forwards that flag here.)")
        return 1
    if tag == ODID_BASELINE_RELEASE:
        print(f"   ok: latest core-c release is still {tag} ({date}); nothing new to chase")
        return 0
    print(f"   !! core-c shipped {tag} ({date}); your baseline is {ODID_BASELINE_RELEASE}")
    print("      review the release, re-vendor opendroneid/ (.c + .h) if it matters,")
    print("      then bump ODID_BASELINE_RELEASE in this script")
    return 1


def check_odid_copies():
    """The opendroneid decoder is vendored TWICE, on purpose.

    lib/acab_core/opendroneid/ is what the product links; src/odid-sim/ carries its own copy so
    the bench simulator stays self-contained and does not drag in the rest of acab_core (see the
    odid-sim env in platformio.ini). That layout is fine, but it has one failure mode: check_odid
    above says to re-vendor "opendroneid/" in the SINGULAR, and a re-vendor that updates one copy
    and forgets the other leaves a bench simulator that silently disagrees with the receiver it
    exists to test. A test tool that lies is worse than no test tool.

    So assert byte-identity instead of trusting whoever does the next re-vendor to remember.
    """
    print("\n== opendroneid vendored copies (must stay identical) ==")
    pairs = [
        ("lib/acab_core/opendroneid/opendroneid.c", "src/odid-sim/opendroneid.c"),
        ("lib/acab_core/opendroneid/opendroneid.h", "src/odid-sim/opendroneid.h"),
    ]
    drift = 0
    for a, b in pairs:
        pa = os.path.join(repo_root(), "firmware", a)
        pb = os.path.join(repo_root(), "firmware", b)
        if not os.path.exists(pa) or not os.path.exists(pb):
            print(f"   WARN missing: {a if not os.path.exists(pa) else b}")
            drift += 1
            continue
        ha = hashlib.sha256(open(pa, "rb").read()).hexdigest()
        hb = hashlib.sha256(open(pb, "rb").read()).hexdigest()
        if ha == hb:
            print(f"   ok: {os.path.basename(pa):15} identical ({ha[:12]})")
        else:
            print(f"   !! {os.path.basename(pa)} DIFFERS between the two vendored copies")
            print(f"      {a}  {ha[:12]}")
            print(f"      {b}  {hb[:12]}")
            print("      re-vendor BOTH, or the bench simulator no longer matches the receiver")
            drift += 1
    return drift


# The body of `void acabSanitizeAscii(char* dst, const uint8_t* src, size_t n, size_t cap) { ... }`.
# Non-greedy up to a closing brace in COLUMN ZERO, which is the function's own; every brace inside
# it is indented.
ASCII_CLAMP_RE = re.compile(r"void\s+acabSanitizeAscii\s*\([^)]*\)\s*\{(.*?)\n\}", re.S)


def _clamp_body(rel):
    """acabSanitizeAscii's body in `rel`, comments stripped and whitespace collapsed, or None."""
    m = ASCII_CLAMP_RE.search(read_local(rel))
    if not m:
        return None
    return " ".join(re.sub(r"//[^\n]*", "", m.group(1)).split())


def check_ascii_clamp_copies():
    """The ingest clamp is duplicated into the host tests, on purpose. Assert byte equality.

    run.sh compiles exactly ONE classifier source next to each test, so a suite whose classifier
    calls acabSanitizeAscii (acab_scanner.cpp's, which the harness never compiles) has to carry a
    link stub, and several do. Those copies are NOT inert: the tests assert the exact clamped
    output strings, so if the real clamp changes - a wider printable range, a different truncation
    rule, a rejection instead of a substitution - the host suite keeps asserting the OLD firmware
    behaviour and reports PASS on strings the board would now emit differently.

    Same guard, same reasoning as the vendored opendroneid copies and the two FAQ copies. Discovered
    by glob rather than listed, so a NEW suite that copies the function is covered the day it lands.
    """
    print("\n== acabSanitizeAscii copies (host-test stubs must match the real clamp) ==")
    real = _clamp_body(LOCAL_ASCII_CLAMP)
    if real is None:
        print(f"   !! could not find acabSanitizeAscii in {LOCAL_ASCII_CLAMP}")
        print("      it moved (update LOCAL_ASCII_CLAMP) or changed shape; until then this is blind")
        return 1
    root = repo_root()
    drift = 0
    copies = 0
    for path in sorted(glob.glob(os.path.join(root, HOST_TESTS_GLOB))):
        rel = os.path.relpath(path, root)
        body = _clamp_body(rel)
        if body is None:
            continue                      # this suite links nothing that needs the stub
        copies += 1
        if body == real:
            print(f"   ok: {os.path.basename(path):22} matches")
        else:
            print(f"   !! {rel} has DRIFTED from {LOCAL_ASCII_CLAMP}")
            print("      that suite is asserting the OLD clamp's output; re-copy the body verbatim")
            drift += 1
    if copies == 0:
        print("   no host-test copies found (correct if the clamp now lives in a shared header)")
    return drift


# A relatedHelp key as both apps write it: SCREAMING_CASE, DIGITS ALLOWED after the first
# character. Both parsers below used to bake a digit-free name class into the match itself, and
# that does not truncate a name carrying a digit - it fails the whole match, because what follows
# the name (a closing quote on iOS, an open paren on Android) then no longer lines up. So
# AXON_FLEET3 would vanish from BOTH sides at once: the two sets still agree, the mismatch guard
# below stays quiet, and the new category ships with a silently hidden Related Help panel on both
# platforms. That is the exact commit shape this check exists to catch.
#
# So: match names PERMISSIVELY, then validate against this. A token the validator rejects is
# REPORTED, never dropped. A key this file cannot read is a key the coverage loop never checks,
# and a silent drop reads downstream as a pass.
FAQ_KEY_RE = re.compile(r"[A-Z][A-Z0-9_]*")


def _ios_faq_keys():
    """iOS's DeviceType.faqKey keys, as (keys, unreadable).

    "" is not a key: those arms are the deliberate no-panel ones. (None, []) when the faqKey
    block itself cannot be found. `unreadable` carries one line per thing this parser saw but
    could not turn into a key, so the caller fails loudly instead of checking a short list.
    """
    m = re.search(r"var faqKey: String \{(.*?)\n    \}", read_local(IOS_DEVICE_TYPE), re.S)
    if not m:
        return None, []
    body = m.group(1)
    keys, unreadable = set(), []
    literals = re.findall(r'return "([^"]*)"', body)
    for literal in literals:
        if not literal:
            continue
        if FAQ_KEY_RE.fullmatch(literal):
            keys.add(literal)
        else:
            unreadable.append(f"faqKey returns {literal!r}, which is not a SCREAMING_CASE key")
    # Every arm has to BE a plain string literal for the line above to see it. An arm returning a
    # constant, an interpolation or a call is a key this parser is blind to: the same hole in a
    # different shape, so count the arms rather than trusting the shape to stay.
    arms = len(re.findall(r"\breturn\b", body))
    if arms != len(literals):
        unreadable.append(f"{arms - len(literals)} faqKey arm(s) return something other than a "
                          "string literal, so their key was not read")
    return keys, unreadable


def _android_faq_keys():
    """Android's keys ARE the enum constant names, minus the ones faqKey maps to "".

    Same (keys, unreadable) contract as _ios_faq_keys. Comments come out of the constant list
    first: they are prose, and a capitalised word in prose is not an enum constant.
    """
    text = read_local(AND_DEVICE_TYPE)
    enum = re.search(r"enum class DeviceType\(val raw: Int\) \{(.*?);", text, re.S)
    getter = re.search(r"val faqKey: String\s*\n\s*get\(\) = when \(this\) \{(.*?)\n\s*\}", text, re.S)
    if not enum or not getter:
        return None, []
    body = re.sub(r"//[^\n]*", "", re.sub(r"/\*.*?\*/", "", enum.group(1), flags=re.S))
    keys, unreadable = set(), []
    names = re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\d+\s*\)", body)
    for name in names:
        if FAQ_KEY_RE.fullmatch(name):
            keys.add(name)
        else:
            unreadable.append(f"enum constant {name} is not a SCREAMING_CASE key")
    # Same blindness check as the iOS side: count what LOOKS like a constant declaration against
    # what actually parsed, so a raw value written as 0x0B or as an expression gets reported
    # instead of quietly taking its name with it.
    declared = len(re.findall(r"\b[A-Za-z_][A-Za-z0-9_]*\s*\(", body))
    if declared != len(names):
        unreadable.append(f"{declared - len(names)} DeviceType constant declaration(s) did not "
                          "parse, so their key was not read")
    for line in getter.group(1).splitlines():
        if "->" in line and '""' in line:
            keys -= set(re.findall(r"\b([A-Z][A-Z0-9_]*)\b", line.split("->")[0]))
    return keys, unreadable


def check_faq_copies():
    """The bundled FAQ ships as ONE file copied into both app resource trees. Assert byte equality.

    faq-content.json is the shared answer set that must read identically on iOS and Android. Keeping it as a
    Swift literal and a Kotlin literal would be two hand-maintained copies of the same prose, and
    cross-platform copy drift is the most recurring defect class in this repo. So it is one file,
    duplicated verbatim into two resource trees because neither build system will reach outside its
    own tree, and this check is what makes the duplication safe: edit one, the build tells you.

    Same guard, same reasoning as the vendored opendroneid copies above.
    """
    root = repo_root()
    a = os.path.join(root, "ios/Beacons/Resources/faq-content.json")
    b = os.path.join(root, "android/app/src/main/assets/faq-content.json")
    print("\n== bundled FAQ content (both app copies must be identical) ==")
    missing = [p for p in (a, b) if not os.path.exists(p)]
    if missing:
        for p in missing:
            print(f"   !! MISSING: {os.path.relpath(p, root)}")
        return len(missing)
    ha = hashlib.sha256(open(a, "rb").read()).hexdigest()
    hb = hashlib.sha256(open(b, "rb").read()).hexdigest()
    if ha != hb:
        print("   !! DRIFT: the two faq-content.json copies differ")
        print(f"      ios     {ha[:12]}")
        print(f"      android {hb[:12]}")
        print("      fix: copy the intended one over the other, they are meant to be byte-identical")
        return 1
    # A parse check too: a syntactically broken JSON degrades to an EMPTY help screen at runtime
    # on both platforms (both parsers swallow the error by design), so the build is the only place
    # it can be caught.
    try:
        d = json.loads(open(a, encoding="utf-8").read())
        nq = sum(len(sec.get("questions", [])) for sec in d.get("sections", []))
        print(f"   ok: identical ({ha[:12]}), {len(d.get('sections', []))} sections, {nq} questions, "
              f"{len(d.get('support', []))} support rows")
    except Exception as e:
        print(f"   !! faq-content.json does not parse: {e}")
        return 1
    # Related-help coverage: both apps key the detail screen's Related Help panel off the
    # DeviceType faq key into relatedHelp. A key with no entry HIDES the panel silently at
    # runtime (both apps skip rendering on an empty lookup), so a category can lose its help
    # with nothing failing anywhere - the build is the only place it can be caught.
    #
    # DERIVED from the two DeviceType enums, never hand-listed. A hardcoded list is checked
    # against the JSON but not against the apps, so a NEW category with no relatedHelp row passed
    # silently: the one commit this check exists for. Reading both sources also catches the two
    # enums disagreeing about a key, which the shared JSON has no way to express.
    ios_keys, ios_unreadable = _ios_faq_keys()
    and_keys, and_unreadable = _android_faq_keys()
    if ios_keys is None or and_keys is None:
        blind = IOS_DEVICE_TYPE if ios_keys is None else AND_DEVICE_TYPE
        print(f"   !! could not read the faqKey list out of {blind}")
        print("      relatedHelp coverage cannot be checked; fix the source or the parser above")
        return 1
    # A key that did not parse is a key nothing below checks, and the two sets would still AGREE
    # about it, because both parsers would miss it in the same way. Say so instead of printing an
    # "ok" derived from a short list.
    if ios_unreadable or and_unreadable:
        print("   !! a DeviceType faq key did not parse, so it was NOT checked for coverage:")
        for msg in ios_unreadable:
            print(f"      iOS      {msg}")
        for msg in and_unreadable:
            print(f"      Android  {msg}")
        print("      keys are SCREAMING_CASE (digits allowed after the first character). Rename")
        print("      it, or teach FAQ_KEY_RE and the parsers in this file the new shape.")
        return 1
    if ios_keys != and_keys:
        print("   !! the two DeviceType enums disagree about the relatedHelp keys")
        print(f"      iOS only:     {sorted(ios_keys - and_keys) or '-'}")
        print(f"      Android only: {sorted(and_keys - ios_keys) or '-'}")
        print("      the JSON is shared, so one platform would silently lose its panel")
        return 1
    faq_keys = sorted(ios_keys)
    related = d.get("relatedHelp", {})
    known_q = {q.get("id") for sec in d.get("sections", []) for q in sec.get("questions", [])}
    bad = 0
    for key in faq_keys:
        rows = related.get(key, [])
        if not rows:
            print(f"   !! relatedHelp has no entries for {key}: both apps silently hide the panel")
            bad += 1
            continue
        for qid in rows:
            if qid not in known_q:
                print(f"   !! relatedHelp[{key}] points at unknown question id '{qid}'")
                bad += 1
    if not bad:
        print(f"   ok: relatedHelp covers all {len(faq_keys)} categories, every id resolves")
    return bad


# Constants each app declares SEPARATELY and whose source literal must stay byte-identical. Both
# sides of every row already say so in their own comments, and a comment is not a check: this is the
# faq-content.json guard above extended to the strings that could NOT move into that shared file,
# because they are code constants rather than content.
#
# WHAT A ROW MAY PIN. The comparison is of the literal AS WRITTEN, so a constant whose two sides
# need different escaping (a Swift interpolation, a "$" Kotlin has to escape) does not belong here:
# it would report drift between two correct copies, and a guard that cries wolf gets ignored.
#
# `kind` is "string" for one literal and "list" for an ordered list of them, where ORDER is part of
# the contract.
SHARED_CONSTANTS = (
    {
        "what": "detection CSV columns",
        "kind": "list",
        "why": "the redaction policy names these columns as STRINGS, so a rename on one platform"
               " ships a coordinate under a new name in a file whose disclosure says it was removed",
        "ios": (IOS_CONTRIBUTION_CSV,
                r"static\s+let\s+detectionColumns\s*:\s*\[String\]\s*=\s*\[(.*?)\]"),
        "android": (AND_BLE_MANAGER,
                    r"\bval\s+DETECTION_CSV_COLUMNS\s*:\s*List<String>\s*=\s*listOf\((.*?)\)"),
    },
    {
        "what": "pairing-window hint",
        "kind": "string",
        "why": "user-facing recovery copy: the same failure has to read the same on both phones",
        "ios": (IOS_BLE_MANAGER, r'static\s+let\s+pairWindowHint\s*=\s*"((?:[^"\\]|\\.)*)"'),
        "android": (AND_BLE_MANAGER,
                    r'\bconst\s+val\s+PAIR_WINDOW_HINT\s*=\s*"((?:[^"\\]|\\.)*)"'),
    },
)


def _pinned_constant(rel, pattern, kind):
    """The pinned value in `rel` as (value, reason). value is None when it could not be read.

    Zero matches and two matches are BOTH failures, and so is a list that parsed to nothing: a pin
    this parser cannot read is a pin nothing compares, and both sides would then be missing it in
    the same way, so the sets would still "agree". Same rule as the faqKey parsers above.
    """
    try:
        text = read_local(rel)
    except OSError as exc:
        return None, f"{rel} could not be read ({exc})"
    found = re.findall(pattern, text, re.S)
    if len(found) != 1:
        return None, f"{len(found)} declarations matched in {rel} (expected exactly 1)"
    if kind == "string":
        return found[0], None
    items = re.findall(r'"([^"]*)"', found[0])
    if not items:
        return None, f"the declaration in {rel} parsed to an empty list"
    return items, None


def check_shared_constants():
    """One rule, two declarations. Assert the literals themselves, not the comments claiming them."""
    print("\n== cross-platform constants (iOS and Android must declare the same literal) ==")
    drift = 0
    for pin in SHARED_CONSTANTS:
        what, kind = pin["what"], pin["kind"]
        ios_value, ios_reason = _pinned_constant(pin["ios"][0], pin["ios"][1], kind)
        and_value, and_reason = _pinned_constant(pin["android"][0], pin["android"][1], kind)
        if ios_value is None or and_value is None:
            print(f"   !! {what}: could not be read, so it was NOT compared")
            for reason in (ios_reason, and_reason):
                if reason:
                    print(f"      {reason}")
            print("      it moved or changed shape; fix the source or the pattern in"
                  " SHARED_CONSTANTS")
            drift += 1
            continue
        if ios_value == and_value:
            shown = ios_value if kind == "string" else f"{len(ios_value)} entries, in order"
            print(f"   ok: {what:24} identical ({shown})")
            continue
        print(f"   !! {what} DIFFERS between the two apps")
        print(f"      {pin['ios'][0]}")
        print(f"      {pin['android'][0]}")
        if kind == "list":
            only_ios = [v for v in ios_value if v not in and_value]
            only_and = [v for v in and_value if v not in ios_value]
            print(f"      iOS only:     {only_ios or '-'}")
            print(f"      Android only: {only_and or '-'}")
            if not only_ios and not only_and:
                print("      same entries, DIFFERENT ORDER, which is the same defect here")
        else:
            print(f"      iOS      {ios_value!r}")
            print(f"      Android  {and_value!r}")
        print(f"      {pin['why']}")
        drift += 1
    return drift


def check_privacy_contract():
    """Keep both apps on the one truthful privacy page and pin its seizure/location disclosures.

    The product previously had two hand-maintained policies. Both apps opened the stale one, which
    claimed the phone fix never left the phone after firmware had begun storing that fix in the
    offline buffer. Pinning only iOS == Android would let both drift together, so compare each to
    the expected canonical URL and verify the canonical page still carries the facts that made the
    old copy materially false.
    """
    print("\n== canonical privacy contract (one app-linked policy) ==")
    drift = 0
    for label, rel in (("iOS", IOS_SETTINGS), ("Android", AND_DEVICE_SCREEN)):
        text = read_local(rel)
        count = text.count(CANONICAL_PRIVACY_URL)
        if count == 1:
            print(f"   ok: {label:7} opens {CANONICAL_PRIVACY_URL}")
        else:
            print(f"   !! {label} contains the canonical privacy URL {count} times (expected 1)")
            print(f"      {rel}")
            drift += 1

    policy = read_local(CANONICAL_PRIVACY).lower()
    required = (
        "sends its current fix",
        "about 18 hours",
        "keeps a copy of that key",
        "not sealed against a seized board",
        "site host sees the request",
    )
    missing = [fact for fact in required if fact not in policy]
    if missing:
        print(f"   !! {CANONICAL_PRIVACY} lost required disclosure(s):")
        for fact in missing:
            print(f"      {fact!r}")
        drift += len(missing)
    else:
        print("   ok: canonical policy discloses GPS transfer/retention and seized-board key risk")
    # soyboi.tech currently sits behind Cloudflare, while this canonical document itself is
    # deployed by GitHub Pages. Naming the latter as the receiver of firmware/dataset requests is
    # materially wrong and already regressed once; keep the request disclosure host-neutral.
    if "github pages" in policy:
        print(f"   !! {CANONICAL_PRIVACY} misidentifies the host receiving app requests")
        drift += 1
    return drift


def main():
    ap = argparse.ArgumentParser(
        description="ACAB signature + vendored-copy drift check (reports only, changes nothing)")
    ap.add_argument("--offline", action="store_true",
                    help="skip the upstream release/list watch instead of failing on an "
                         "unreachable network. For a bench run with no connectivity, NOT for CI: "
                         "a watcher that skipped itself has watched nothing.")
    args = ap.parse_args()
    print("ACAB signature drift check (reports only, changes nothing)\n")
    drift = (check_flock(args.offline) + check_odid(args.offline) + check_odid_copies()
             + check_faq_copies() + check_ascii_clamp_copies() + check_shared_constants()
             + check_privacy_contract())
    print()
    if drift:
        print(f"DRIFT: {drift} item(s) need a look. Review and re-port by hand.")
        sys.exit(1)
    print("No drift detected.")
    sys.exit(0)


if __name__ == "__main__":
    main()
