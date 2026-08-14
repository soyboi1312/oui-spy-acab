/*
 * ACAB - marker-window accounting (pure decision, no platform deps).
 *
 * Extracted from acab_scanner.cpp for the same reason sink_claim.h was: the interesting part is a
 * bookkeeping invariant, the surrounding code needs Arduino, NimBLE and FreeRTOS, and an invariant
 * nothing can execute off-target is an invariant nobody has checked.
 *
 * THE INVARIANT. Every advert offered to an open window ends up in exactly one of three places:
 *
 *     listedObs + otherObs + fullObs == totalObs
 *
 * listedObs is the SUM OF n OVER THE ROWS THAT SURVIVED, not the number of rows. Those are
 * different units, and conflating them is how the first version of this claimed to account for
 * everything while doing nothing of the sort: `listed` counted MACs, the other two counted
 * adverts, so the equation could not balance even in principle. acabMarkAccounted() exists so the
 * summary can assert the real one rather than assert a plausible-looking sentence.
 *
 * Three ways an observation leaves the listing:
 *   - the device never became actionable (no vendor identifier, no classifier hit, too far away),
 *   - its row was EVICTED to make room for an evidence-bearing device, and its accumulated n is
 *     inherited by otherObs rather than vanishing,
 *   - the table was full of protected rows and nothing could be displaced (fullObs).
 *
 * TIME IS AN INPUT. nowMs is passed in, never read here. On target that is what lets the caller
 * sample the clock INSIDE the lock that orders the table mutation, so an advert can never carry a
 * timestamp from before the window it lands in (which underflows first=) or after the window it
 * belongs to (which prints last= beyond dur=). Off target it is what makes the tests deterministic.
 */
#ifndef ACAB_MARK_TABLE_H
#define ACAB_MARK_TABLE_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <string.h>

#define ACAB_MARK_NAME_LEN 24

struct AcabMarkRec {
    uint8_t  mac[6];
    char     name[ACAB_MARK_NAME_LEN];
    uint32_t n;             // observations attributed to THIS row
    int8_t   best;
    uint8_t  vendorMask;    // CONFIRMED vendor identifiers (AD 0x02/0x03/0x16 UUIDs and 0xFF company IDs)
    uint8_t  solicitMask;   // SOLICITED (AD 0x14): a request FOR a service, not vendor evidence
    uint8_t  matchedType;   // AcabDeviceType a shipping classifier assigned; 0xFF = none
    uint32_t firstMs, lastMs;
    bool     used;
};

struct AcabMarkTable {
    AcabMarkRec* rec;
    size_t       cap;
    uint32_t     otherObs;   // observations not represented by any surviving row
    uint32_t     fullObs;    // observations dropped with nothing evictable
    uint32_t     totalObs;   // every observation offered while open; the control total
    uint32_t     startMs;
    bool         open;
};

/// Clear the table and open a new window at nowMs.
static inline void acabMarkReset(AcabMarkTable* t, uint32_t nowMs) {
    if (!t || !t->rec) return;
    memset(t->rec, 0, sizeof(AcabMarkRec) * t->cap);
    t->otherObs = t->fullObs = t->totalObs = 0;
    t->startMs = nowMs;
    t->open = true;
}

/// Offer one observation to the open window. `nearRssi` is the proximity threshold at which a
/// device with no other evidence still earns a row.
static inline void acabMarkNote(AcabMarkTable* t, const uint8_t mac[6], int rssi, const char* name,
                                uint8_t vendorMask, uint8_t solicitMask,
                                bool matched, uint8_t matchedType,
                                uint32_t nowMs, int nearRssi) {
    if (!t || !t->rec || !t->open) return;
    t->totalObs++;                       // counted BEFORE any branch: the control total must be
                                         // incremented on every path or the invariant is vacuous.

    AcabMarkRec* freeSlot = NULL;
    AcabMarkRec* weakest  = NULL;        // an RSSI-only row, displaceable by real evidence
    for (size_t i = 0; i < t->cap; i++) {
        AcabMarkRec* m = &t->rec[i];
        if (m->used && memcmp(m->mac, mac, 6) == 0) {
            m->n++;
            if ((int8_t)rssi > m->best) m->best = (int8_t)rssi;
            m->vendorMask  |= vendorMask;
            m->solicitMask |= solicitMask;
            if (matched) m->matchedType = matchedType;
            if (name && name[0] && !m->name[0]) {
                size_t k = 0;
                for (; k + 1 < ACAB_MARK_NAME_LEN && name[k]; k++) m->name[k] = name[k];
                m->name[k] = 0;
            }
            m->lastMs = nowMs;
            return;
        }
        if (!m->used) { if (!freeSlot) freeSlot = m; continue; }
        if (!m->vendorMask && !m->solicitMask && m->matchedType == 0xFF &&
            (!weakest || m->best < weakest->best)) weakest = m;
    }

    const bool strong = (vendorMask || solicitMask || matched);
    if (!strong && rssi < nearRssi) { t->otherObs++; return; }

    AcabMarkRec* slot = freeSlot;
    if (!slot && strong) slot = weakest;      // evidence displaces proximity, never the reverse
    if (!slot) { t->fullObs++; return; }

    // An eviction inherits the evicted row's observations. Without this the summary loses them
    // silently and still reads as complete, which is the failure this whole header exists to make
    // impossible to reintroduce unnoticed.
    if (slot->used) t->otherObs += slot->n;

    memset(slot, 0, sizeof(*slot));
    memcpy(slot->mac, mac, 6);
    slot->n = 1;
    slot->best = (int8_t)rssi;
    slot->vendorMask = vendorMask;
    slot->solicitMask = solicitMask;
    slot->matchedType = matched ? matchedType : 0xFF;
    if (name && name[0]) {
        size_t k = 0;
        for (; k + 1 < ACAB_MARK_NAME_LEN && name[k]; k++) slot->name[k] = name[k];
        slot->name[k] = 0;
    }
    slot->firstMs = slot->lastMs = nowMs;
    slot->used = true;
}

/// Number of surviving ROWS (distinct MACs listed).
static inline uint32_t acabMarkListedMacs(const AcabMarkTable* t) {
    uint32_t n = 0;
    if (!t || !t->rec) return 0;
    for (size_t i = 0; i < t->cap; i++) if (t->rec[i].used) n++;
    return n;
}

/// Sum of n over the surviving rows: OBSERVATIONS, the unit the invariant is expressed in.
static inline uint32_t acabMarkListedObs(const AcabMarkTable* t) {
    uint32_t n = 0;
    if (!t || !t->rec) return 0;
    for (size_t i = 0; i < t->cap; i++) if (t->rec[i].used) n += t->rec[i].n;
    return n;
}

/// The invariant. Printed as accounted=yes/no so a reader never has to trust it silently.
static inline bool acabMarkAccounted(const AcabMarkTable* t) {
    if (!t) return false;
    return acabMarkListedObs(t) + t->otherObs + t->fullObs == t->totalObs;
}

#endif // ACAB_MARK_TABLE_H
