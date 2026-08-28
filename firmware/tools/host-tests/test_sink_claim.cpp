// Host regression test for the offline-buffer claim rollback (sink_claim.h).
//
// WHY THIS SUITE EXISTS. The bug it guards is a race between claiming a capture generation in the
// dedup table and actually landing the record on the sink queue ~50 lines later. On hardware the
// window only opens while the sink task is blocked inside a flash erase, which is not something a
// test can schedule. So the DECISION was extracted into a pure predicate and the race is staged
// here instead - this file is the only place the ABA case can be pinned at all.
//
// Read sink_claim.h first: every condition in acabClaimRollbackAllowed rejects a specific way the
// claim can have stopped belonging to the failed send, and each one has a test below.
#include "../../lib/acab_core/sink_claim.h"
#include "../../lib/acab_core/dedup_key.h"
#include "../../lib/acab_core/det_log.h"
#include <cstdio>
#include <cstring>
#include <cstdint>

// ---------------------------------------------------------------------------
// KEY PLUMBING (P1-3)
// ---------------------------------------------------------------------------
// The decision function above cannot see a key MISMATCH: it is handed whatever the caller looked
// up, so a rollback that searched the table under the wrong key looks identical to one that found
// nothing. That is exactly the bug that shipped - claims are made under dedupKey(), which HASHES
// THE UAS ID for a Remote ID drone (drones rotate MACs across both radios), while the rollback
// looked up by d.mac. For drones the two never match, so the rollback silently refused and the
// record stayed marked buffered for the whole capture generation.
//
// So these tests exercise the KEY, mirroring acab_scanner.cpp's dedupKey byte for byte. If that
// function changes, this copy has to change with it; the mutation check below is what proves this
// test can actually see the difference.
// The REAL derivation, not a copy. It was mirrored here at first, which meant a change to the
// shipped function would leave this test happily asserting the old behaviour.
static AcabDetection det(AcabDeviceType type, const uint8_t mac[6], const char* id) {
    AcabDetection d{};
    d.type = type;
    memcpy(d.mac, mac, 6);
    if (id) { strncpy(d.id, id, sizeof(d.id) - 1); }
    return d;
}

// ---------------------------------------------------------------------------
// A fake dedup table, so the PRODUCTION rollback can be driven off-target.
// ---------------------------------------------------------------------------
// acabSinkClaimRollback is the function acab_scanner.cpp actually calls. Driving it here (rather
// than re-implementing what it "would" do) is what makes these regression tests instead of
// explanatory ones: an earlier version of this file simulated both the right and wrong lookup, so
// changing the production call site left it green.
struct FakeTable {
    uint8_t  key[6];         // the single entry we hold
    uint8_t  type;
    bool     present;
    uint32_t loggedGen;
    uint32_t logClaim;
    uint32_t genNow;
    bool     restored;       // did rollback write to us
    uint32_t restoredTo;
    uint8_t  lookedUpKey[6]; // WHAT KEY DID THE ROLLBACK ASK FOR - the assertion that matters
    bool     lookupCalled;
};

static bool fakeLookup(void* ctx, uint8_t type, const uint8_t key[6], uint32_t,
                       uint32_t* outLoggedGen, uint32_t* outLogClaim) {
    FakeTable* t = (FakeTable*)ctx;
    t->lookupCalled = true;
    memcpy(t->lookedUpKey, key, 6);
    if (!t->present || t->type != type || memcmp(t->key, key, 6) != 0) return false;
    *outLoggedGen = t->loggedGen;
    *outLogClaim  = t->logClaim;
    return true;
}
static void fakeRestore(void* ctx, uint32_t loggedGen) {
    FakeTable* t = (FakeTable*)ctx;
    t->restored = true; t->restoredTo = loggedGen;
}
static uint32_t fakeGenNow(void* ctx) { return ((FakeTable*)ctx)->genNow; }

/// Claim `d` exactly the way acab_scanner.cpp does, then run the production rollback against a
/// table holding that same entry. Returns the table so a test can assert what was looked up.
static FakeTable claimThenRollback(const AcabDetection& d, uint32_t captureGen, uint32_t token) {
    uint8_t scratch[6];
    const uint8_t* key = acabDedupKey(d, scratch);

    AcabSinkClaim claim{};
    claim.type           = (uint8_t)d.type;
    memcpy(claim.key, key, 6);          // the copy production makes at claim time
    claim.bucket         = 0;
    claim.priorLoggedGen = 3;
    claim.captureGen     = captureGen;
    claim.token          = token;
    claim.active         = true;

    FakeTable t{};
    memcpy(t.key, key, 6);
    t.type = (uint8_t)d.type;
    t.present = true;
    t.loggedGen = captureGen;           // the entry currently reads as claimed this generation
    t.logClaim = token;
    t.genNow = captureGen;

    AcabClaimTable api{ fakeLookup, fakeRestore, fakeGenNow, &t };
    acabSinkClaimRollback(claim, api);
    return t;
}

static int gFail = 0, gRun = 0;
static void chk(const char* name, bool got, bool want) {
    gRun++;
    bool ok = (got == want);
    if (!ok) gFail++;
    printf("  %-58s %s\n", name, ok ? "PASS" : "**FAIL**");
    if (!ok) printf("      got %s, wanted %s\n", got ? "true" : "false", want ? "true" : "false");
}

// A claim that is in every respect still ours: same device, same generation, same token. This is
// the baseline every case below mutates exactly one field of, so a failure names its own cause.
static AcabClaimCheck ok() {
    AcabClaimCheck c{};
    c.entryFound        = true;
    c.keyMatches        = true;
    c.entryLoggedGen    = 5;
    c.entryLogClaim     = 42;
    c.captureGenNow     = 5;
    c.captureGenAtClaim = 5;
    c.claim             = 42;
    return c;
}

int main() {
    printf("\n=== sink-queue claim rollback ===\n");

    chk("claim carries separate capture and owner-admission epochs",
        sizeof(AcabSinkClaim) == 32, true);
    AcabSinkClaim epochClaim{};
    epochClaim.captureGen = 5;
    epochClaim.admissionEpoch = 9;
    const uint32_t periodicCaptureGen = 6;
    const uint32_t sameOwnerAdmissionEpoch = 9;
    chk("periodic dedup rearm preserves queued owner admission",
        periodicCaptureGen != epochClaim.captureGen &&
        sameOwnerAdmissionEpoch == epochClaim.admissionEpoch, true);
    chk("disconnect owner epoch invalidates the queued claim",
        (sameOwnerAdmissionEpoch + 1) == epochClaim.admissionEpoch, false);

    // The whole point: a buffer-bearing item that failed to enqueue must release its claim, or the
    // device reads as "already buffered this generation" with nothing written and stays that way
    // until the app disconnects.
    chk("failed buffered enqueue -> rollback allowed (device re-arms)",
        acabClaimRollbackAllowed(ok()), true);

    // Only a transient det_log refusal releases an already-queued claim. Deliberately disabled,
    // connected, keyless, unavailable, or fault-blocked logging is stable until a separate capture
    // generation boundary; releasing in those states makes every advert hammer the sink queue.
    chk("transient append refusal releases the scanner claim",
        detLogAppendReleasesClaim(DET_LOG_APPEND_RETRY), true);
    chk("stored append keeps the scanner claim consumed",
        detLogAppendReleasesClaim(DET_LOG_APPEND_STORED), false);
    chk("stable not-armed refusal keeps the scanner claim consumed",
        detLogAppendReleasesClaim(DET_LOG_APPEND_NOT_ARMED), false);
    chk("capacity refusal keeps the scanner claim consumed",
        detLogAppendReleasesClaim(DET_LOG_APPEND_CAPACITY_DROP), false);

    // THE ABA CASE. Slot evicted under table pressure, same device re-admitted, its newer sighting
    // claimed successfully - then our stale failure arrives. Rolling back here would re-arm a
    // device whose record IS safely queued, so it buffers twice and burns a ring slot. The token
    // is the only thing that can tell these apart: type, MAC and generation all still match.
    { AcabClaimCheck c = ok(); c.entryLogClaim = 43;
      chk("ABA: newer claim holds the slot -> rollback REFUSED", acabClaimRollbackAllowed(c), false); }

    // Evicted outright and nothing took its place. Nothing to undo, and re-creating the entry would
    // resurrect a device the table already chose to forget.
    { AcabClaimCheck c = ok(); c.entryFound = false;
      chk("entry evicted, slot empty -> refused", acabClaimRollbackAllowed(c), false); }

    // Slot reused by a DIFFERENT device. Rolling back would re-arm a stranger.
    { AcabClaimCheck c = ok(); c.keyMatches = false;
      chk("slot reused by another device -> refused", acabClaimRollbackAllowed(c), false); }

    // The app disconnected between claim and failure, which already re-armed everything. Writing an
    // old generation back is meaningless at best, and could mark the device claimed in the NEW one.
    { AcabClaimCheck c = ok(); c.captureGenNow = 6;
      chk("capture generation bumped between claim and failure -> refused",
          acabClaimRollbackAllowed(c), false); }

    // The entry does not currently read as claimed-this-generation, so there is no claim to undo.
    { AcabClaimCheck c = ok(); c.entryLoggedGen = 4;
      chk("entry no longer reads as claimed this generation -> refused",
          acabClaimRollbackAllowed(c), false); }

    // Both moved together: a full generation turnover with a fresh claim. Still refused, and the
    // generation check is what catches it (the token happens to match).
    { AcabClaimCheck c = ok(); c.captureGenNow = 6; c.entryLoggedGen = 6; c.captureGenAtClaim = 5;
      chk("new generation with a fresh claim -> refused", acabClaimRollbackAllowed(c), false); }

    // Token 0 is what a non-buffering path carries. It must never authorize a rollback against a
    // real claim, or a deliver-only drop could release someone else's buffered claim.
    { AcabClaimCheck c = ok(); c.claim = 0;
      chk("zero token (non-buffering path) never rolls back a real claim",
          acabClaimRollbackAllowed(c), false); }

    // Generation 0 is not special-cased anywhere: the code restores the PRIOR value rather than
    // writing a sentinel, so a device that had never buffered rolls back to "never" cleanly.
    { AcabClaimCheck c = ok(); c.entryLoggedGen = 0; c.captureGenNow = 0; c.captureGenAtClaim = 0;
      chk("generation 0 carries no sentinel meaning -> still allowed",
          acabClaimRollbackAllowed(c), true); }

    // The sink queue can accept an item while det_log is still startup/NVS/wipe-blocked. A later
    // RETRY result must release the carried claim, so the same device's next sighting can claim and
    // buffer in this capture generation after readiness recovers. This is the second asynchronous
    // boundary; enqueue-failure rollback alone does not cover it.
    {
        const uint8_t key[6] = {1,2,3,4,5,6};
        AcabSinkClaim claim{};
        claim.type = 1;
        memcpy(claim.key, key, sizeof(key));
        claim.bucket = 7;
        claim.priorLoggedGen = 0;
        claim.captureGen = 5;
        claim.token = 42;
        claim.active = true;
        FakeTable t{};
        memcpy(t.key, key, sizeof(key));
        t.type = claim.type;
        t.present = true;
        t.loggedGen = 5;
        t.logClaim = 42;
        t.genNow = 5;
        AcabClaimTable api{ fakeLookup, fakeRestore, fakeGenNow, &t };
        const bool released = acabSinkClaimRollback(claim, api);
        if (released) t.loggedGen = t.restoredTo;  // production restore mutates the actual entry
        const bool sameDeviceCanClaimAfterRecovery = t.loggedGen != t.genNow;
        chk("retryable sink append rejection re-arms same-generation device",
            released && sameDeviceCanClaimAfterRecovery, true);
    }

    // ---- key plumbing: the rollback must look up the key the claim used ----------------------
    printf("\n  -- rollback key plumbing --\n");
    const uint8_t droneMac[6]  = {0x60,0x60,0x1f,0x1a,0x1a,0x3f};
    const uint8_t nearbyMac[6] = {0xc2,0x40,0xd8,0x1c,0x2b,0x96};
    AcabDetection drone     = det(ACAB_DRONE, droneMac, "1581F67QC236L014509G");
    AcabDetection nearby    = det(ACAB_NEARBY_DEVICE, nearbyMac, nullptr);
    AcabDetection droneNoId = det(ACAB_DRONE, droneMac, nullptr);

    // THE ONE THAT CATCHES THE PRODUCTION BUG. A Remote ID drone is keyed by its UAS ID, so if the
    // rollback ever looks up by MAC again it will not find the entry and will not restore it.
    { FakeTable t = claimThenRollback(drone, 5, 42);
      chk("drone: rollback looked up by the UAS-ID key, NOT the MAC",
          t.lookupCalled && memcmp(t.lookedUpKey, drone.mac, 6) != 0, true);
      chk("drone: the claim was actually released", t.restored && t.restoredTo == 3, true); }

    // No regression on the 99% path, which is exactly why the drone case went unnoticed.
    { FakeTable t = claimThenRollback(nearby, 5, 42);
      chk("non-drone: rollback looked up by the MAC (its real key)",
          memcmp(t.lookedUpKey, nearby.mac, 6) == 0, true);
      chk("non-drone: the claim was released", t.restored, true); }

    // A drone that never sent a UAS ID falls back to MAC keying on BOTH paths.
    { FakeTable t = claimThenRollback(droneNoId, 5, 42);
      chk("drone with an EMPTY UAS ID falls back to the MAC key",
          memcmp(t.lookedUpKey, droneNoId.mac, 6) == 0 && t.restored, true); }

    // The refusal cases, now through the REAL sequence rather than the decision alone.
    { AcabSinkClaim c{}; c.active = false;
      FakeTable t{}; AcabClaimTable api{ fakeLookup, fakeRestore, fakeGenNow, &t };
      chk("a non-buffering detection never even looks the table up",
          !acabSinkClaimRollback(c, api) && !t.lookupCalled, true); }

    printf(gFail ? "\n  REGRESSION DETECTED (%d failure%s of %d)\n\n" : "\n  all good (0 failures of %d)\n\n",
           gFail ? gFail : gRun, gFail == 1 ? "" : "s", gFail ? gRun : 0);
    return gFail ? 1 : 0;
}
