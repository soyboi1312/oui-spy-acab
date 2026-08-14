#!/usr/bin/env python3
"""Watch ACAB's one vendored dependency for upstream drift: the opendroneid decoder.
The Flock OUI table is own-sourced (own field captures plus Flock's IEEE block) and is
no longer diffed against any third-party curated list.

    python3 firmware/tools/check-signature-drift.py

Exits 0 when nothing upstream is missing locally, 1 when there is drift to look
at. It only reports; it never edits anything. Provenance is in CREDITS.md. When an
upstream repo moves a file or renames a branch, update the URLs below.
"""
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


def check_flock():
    print("== Flock OUI tables ==")
    local = extract_ouis(read_local(LOCAL_FLOCK))
    print(f"   local:    {len(local):>3} OUIs  ({LOCAL_FLOCK})")
    upstream = set()
    for url in UPSTREAM_FLOCK_URLS:
        try:
            found = extract_ouis(fetch(url))
            print(f"   upstream: {len(found):>3} OUIs  {url}")
            upstream |= found
        except Exception as exc:  # network / 404 / parse: warn but keep going
            print(f"   WARN could not fetch {url}: {exc}")
    if not upstream:
        print("   Flock OUIs are own-sourced; no third-party list is mirrored (see docs/signatures.md)")
        return 0
    missing = sorted(upstream - local)  # upstream has it, we don't -> drift risk
    extra = sorted(local - upstream)    # ours only -> additions from other sources
    if missing:
        print(f"\n   !! {len(missing)} upstream OUI(s) MISSING locally (possible drift):")
        for o in missing:
            print(f"      {fmt(o)}")
    else:
        print("   ok: every upstream OUI is present locally")
    print(f"   ({len(extra)} local-only OUIs, your superset additions)")
    return len(missing)


def latest_release(repo):
    url = f"https://api.github.com/repos/{repo}/releases/latest"
    req = urllib.request.Request(
        url, headers={"User-Agent": "acab-drift-check", "Accept": "application/vnd.github+json"}
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        data = json.load(r)
    return data.get("tag_name"), (data.get("published_at") or "")[:10]


def check_odid():
    print("\n== opendroneid decoder (release watch) ==")
    try:
        tag, date = latest_release(ODID_REPO)
    except Exception as exc:
        print(f"   WARN could not query {ODID_REPO} releases: {exc}")
        return 0
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


def check_faq_copies():
    """The bundled FAQ ships as ONE file copied into both app resource trees. Assert byte equality.

    faq-content.json is 20 answers that must read identically on iOS and Android. Keeping it as a
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
    # with nothing failing anywhere - the build is the only place it can be caught. This list
    # mirrors the faqKey values the two DeviceType enums can produce; extend it in the same
    # commit that adds a category.
    faq_keys = ["FLOCK_CAMERA", "FLOCK_RAVEN", "BODY_CAM", "DRONE",
                "TRACKER", "WATCHED", "GLASSES", "NETWORK_CAMERA"]
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


def main():
    print("ACAB signature drift check (reports only, changes nothing)\n")
    drift = check_flock() + check_odid() + check_odid_copies() + check_faq_copies()
    print()
    if drift:
        print(f"DRIFT: {drift} item(s) need a look. Review and re-port by hand.")
        sys.exit(1)
    print("No drift detected.")
    sys.exit(0)


if __name__ == "__main__":
    main()
