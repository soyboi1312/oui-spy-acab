/*
 * ACAB - offline-buffer claim rollback (pure decision, no platform deps).
 *
 * THE DEFECT THIS EXISTS FOR. A detection that is going to be written to the offline flash ring
 * "claims" its capture generation in the dedup table at ingest (`e->loggedGen = gCaptureGen`),
 * and only ~50 lines later is handed to the sink task through a FreeRTOS queue. The sink task
 * blocks inside esp_partition_erase_range every 64 records (det_log.cpp), so the queue can be
 * full at exactly that moment. The enqueue result was discarded, which meant a dropped
 * buffer-bearing item left the claim standing: that device was marked "already buffered this
 * generation" while nothing was ever written. It would not buffer again until the app
 * disconnected and bumped the generation. Silent, uncounted, permanent-for-the-generation
 * evidence loss, in the feature whose entire job is capturing what happens while you are away.
 *
 * WHY THE OBVIOUS ROLLBACK IS WRONG. "Put loggedGen back if the entry still matches type+key and
 * still reads as claimed" has an ABA hole. Between the claim and the failed send the slot can be
 * evicted (dedupFind evicts the least-recently-seen entry under table pressure, which is the
 * normal case in Desert mode), the SAME device can be re-admitted into a fresh slot, and that new
 * sighting can make its own successful claim in the same generation. The late failure then rolls
 * back a claim that belongs to a record which IS safely queued, so that device buffers twice and
 * the ring - the scarce resource this all protects - carries a duplicate.
 *
 * The fix is a monotonic claim token. Every claim takes the next value from a counter that only
 * ever moves forward under gDedupMux; rollback additionally requires the entry to still be
 * carrying the exact token the failed send was issued. A re-admitted device holds a different
 * token, so the stale rollback refuses. This header is that decision, kept free of Arduino and
 * FreeRTOS so the host tests can exercise the race directly (test_sink_claim.cpp) - the race is
 * not reproducible on hardware on demand, so a host test is the only place it can be pinned.
 */
#ifndef ACAB_SINK_CLAIM_H
#define ACAB_SINK_CLAIM_H

#include <stdint.h>
#include <stdbool.h>

/// Everything the rollback decision is allowed to look at. The caller resolves the table lookup
/// (which must be LOOKUP-ONLY - see dedupLookup; a recovery path that creates or evicts entries
/// by looking would be a second bug) and fills this in under the dedup mutex.
struct AcabClaimCheck {
    bool     entryFound;         ///< false when the slot was evicted and nothing took its place
    bool     keyMatches;         ///< entry's type+MAC still equal the claiming detection's
    uint32_t entryLoggedGen;     ///< loggedGen currently in the table
    uint32_t entryLogClaim;      ///< claim token currently in the table
    uint32_t captureGenNow;      ///< gCaptureGen as read during recovery
    uint32_t captureGenAtClaim;  ///< gCaptureGen as read when the claim was made
    uint32_t claim;              ///< token this failed send was issued
};

/// True when it is safe to restore the prior loggedGen for a buffer-bearing item that failed to
/// enqueue. Every condition rejects a specific way the claim can have stopped being ours:
///
///   entryFound        - slot evicted outright; nothing to roll back, and re-creating it would
///                       resurrect a device the table already decided to forget.
///   keyMatches        - slot reused by a DIFFERENT device; rolling back would re-arm a stranger.
///   captureGen stable - the app disconnected and bumped the generation, which already re-armed
///                       every device; writing an old generation back would be meaningless at
///                       best and could mark the device as claimed in the NEW generation.
///   entryLoggedGen == captureGenNow
///                     - the entry does not currently read as claimed-this-generation, so there
///                       is no claim to undo.
///   entryLogClaim == claim
///                     - THE ABA GUARD. Same device, same generation, but a newer claim: a later
///                       sighting already queued successfully. Refuse, or that record buffers
///                       twice.
inline bool acabClaimRollbackAllowed(const AcabClaimCheck& c) {
    if (!c.entryFound)                       return false;
    if (!c.keyMatches)                       return false;
    if (c.captureGenNow != c.captureGenAtClaim) return false;
    if (c.entryLoggedGen != c.captureGenNow) return false;
    if (c.entryLogClaim != c.claim)          return false;
    return true;
}

// ---------------------------------------------------------------------------
// The claim itself, and the rollback that owns the production path
// ---------------------------------------------------------------------------
// WHY THIS TYPE EXISTS RATHER THAN PASSING THE DETECTION AROUND. The rollback used to take the
// AcabDetection and look the entry up by `d.mac`. That is wrong for a Remote ID drone, whose dedup
// key is a hash of its UAS ID (see dedup_key.h), so the rollback never found the entry it had
// claimed and the evidence-loss bug survived for exactly that device class.
//
// Fixing the call site alone would leave the same mistake one keystroke away. So the rollback API
// below accepts ONLY this object, which carries the six key bytes copied at claim time. There is no
// AcabDetection in scope inside it, which makes reaching for `d.mac` a compile error rather than a
// judgement call. That is the actual protection; the tests are how we know it works.
struct AcabSinkClaim {
    uint8_t  type;              ///< AcabDeviceType, kept opaque so this header stays dependency-free
    uint8_t  key[6];            ///< the dedup key the claim was made under, COPIED at claim time
    uint32_t bucket;            ///< bucket derived from that same key
    uint32_t priorLoggedGen;    ///< value to restore; NOT a sentinel, see the rollback comment
    uint32_t captureGen;        ///< gCaptureGen as read when the claim was made
    uint32_t admissionEpoch;    ///< owner/link epoch checked atomically by det_log at append
    uint32_t token;             ///< monotonic claim token, the ABA guard
    bool     active;            ///< false when the detection was not buffer-bearing: nothing to undo
};

/// The dedup table, injected. Production passes the real table; the host tests pass a fake, which
/// is the only way to drive the claim -> enqueue -> failed-enqueue -> rollback sequence off-target
/// (acab_scanner.cpp needs Arduino, NimBLE, WiFi and FreeRTOS and cannot be host-compiled).
struct AcabClaimTable {
    /// Look up by (type, key, bucket). LOOKUP ONLY - it must not create or evict, or a failure
    /// path would mutate the table just by looking. Returns false on a miss.
    bool (*lookup)(void* ctx, uint8_t type, const uint8_t key[6], uint32_t bucket,
                   uint32_t* outLoggedGen, uint32_t* outLogClaim);
    /// Restore loggedGen on the entry the immediately preceding lookup found.
    void (*restore)(void* ctx, uint32_t loggedGen);
    /// gCaptureGen as of now.
    uint32_t (*captureGenNow)(void* ctx);
    void* ctx;
};

/// Undo a claim whose buffer-bearing enqueue failed. Returns true if the claim was released, so the
/// device buffers again later in this same capture generation instead of being silently marked done
/// with nothing written.
///
/// Everything it is allowed to look at arrives in `claim`; the caller cannot accidentally hand it a
/// different key than the one the claim was made under, because it has no other key to hand.
inline bool acabSinkClaimRollback(const AcabSinkClaim& claim, const AcabClaimTable& table) {
    if (!claim.active) return false;      // nothing was claimed, so nothing to undo
    uint32_t loggedGen = 0, logClaim = 0;
    const bool found = table.lookup(table.ctx, claim.type, claim.key, claim.bucket,
                                    &loggedGen, &logClaim);
    AcabClaimCheck chk{};
    chk.entryFound        = found;
    chk.keyMatches        = found;        // lookup matched type+key, or it would have missed
    chk.entryLoggedGen    = loggedGen;
    chk.entryLogClaim     = logClaim;
    chk.captureGenNow     = table.captureGenNow(table.ctx);
    chk.captureGenAtClaim = claim.captureGen;
    chk.claim             = claim.token;
    if (!acabClaimRollbackAllowed(chk)) return false;
    table.restore(table.ctx, claim.priorLoggedGen);
    return true;
}

#endif // ACAB_SINK_CLAIM_H
