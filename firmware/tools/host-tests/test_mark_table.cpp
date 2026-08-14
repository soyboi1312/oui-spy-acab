// Host regression test for mark_table.h - marker-window accounting.
//
// WHY THIS EXISTS. The marker summary is meant to be EVIDENCE: someone stands next to a device
// they can see, brackets the visit, and later reads the summary to decide what was there. A
// summary that silently omits observations is worse than no summary, because it reads as complete.
// That has already gone wrong twice in this subsystem - an eviction used to discard the evicted
// row's entire history, and the printed "invariant" mixed a device count with advert counts so it
// could not balance even in principle.
//
// The invariant under test is therefore the whole point:
//
//     listedObs + otherObs + fullObs == totalObs
//
// where listedObs is the SUM OF n over surviving rows, not the number of rows. Every case below
// asserts it, including the ones that exist to break the table.
#include "mark_table.h"
#include <cstdio>
#include <cstring>

static int failures = 0;
static void chkInt(const char* name, long got, long want) {
    bool ok = (got == want);
    printf("  %-56s %s", name, ok ? "PASS" : "**FAIL**");
    if (!ok) { printf("   got %ld want %ld", got, want); failures++; }
    printf("\n");
}
static void chkTrue(const char* name, bool ok) {
    printf("  %-56s %s", name, ok ? "PASS" : "**FAIL**");
    if (!ok) failures++;
    printf("\n");
}

#define CAP 4
static AcabMarkRec  gRec[CAP];
static AcabMarkTable gT = { gRec, CAP, 0, 0, 0, 0, false };

static void mac6(uint8_t* m, uint8_t last) {
    m[0] = 0x00; m[1] = 0x25; m[2] = 0xDF; m[3] = 0x11; m[4] = 0x22; m[5] = last;
}
// vendorMask non-zero = a registered identifier was carried. matched = a shipping classifier
// claimed it. Either makes a device evidence-bearing and therefore protected from eviction.
static void note(uint8_t last, int rssi, uint8_t vendorMask, bool matched, uint32_t now) {
    uint8_t m[6]; mac6(m, last);
    acabMarkNote(&gT, m, rssi, "", vendorMask, 0, matched, matched ? 3 : 0xFF, now, -70);
}

int main() {
    printf("\n=== marker-window accounting (mark_table) ===\n\n");

    printf("-- free-slot insertion --\n");
    acabMarkReset(&gT, 1000);
    note(0x01, -50, 0, false, 1000);          // near enough to earn a row on proximity alone
    chkInt("one near device -> one row", acabMarkListedMacs(&gT), 1);
    chkInt("  ^ carrying one observation", acabMarkListedObs(&gT), 1);
    note(0x01, -48, 0, false, 1100);          // same MAC again
    chkInt("repeat sighting does NOT add a row", acabMarkListedMacs(&gT), 1);
    chkInt("  ^ but does add an observation", acabMarkListedObs(&gT), 2);
    chkInt("  ^ best RSSI tracks the strongest", gRec[0].best, -48);
    chkInt("  ^ lastMs advances, firstMs does not", (long)(gRec[0].lastMs - gRec[0].firstMs), 100);
    chkTrue("accounted", acabMarkAccounted(&gT));

    printf("\n-- a weak, uninteresting device is counted, not listed --\n");
    note(0x02, -95, 0, false, 1200);          // far, no evidence
    chkInt("weak device earns no row", acabMarkListedMacs(&gT), 1);
    chkInt("  ^ its observation lands in other_obs", gT.otherObs, 1);
    chkInt("  ^ total_obs counts it regardless", gT.totalObs, 3);
    chkTrue("accounted", acabMarkAccounted(&gT));

    printf("\n-- evidence displaces proximity, and INHERITS its observations --\n");
    acabMarkReset(&gT, 2000);
    for (uint8_t i = 0; i < CAP; i++) {       // fill every slot with RSSI-only rows
        note((uint8_t)(0x10 + i), -40, 0, false, 2000);
        note((uint8_t)(0x10 + i), -40, 0, false, 2010);   // n = 2 each
    }
    chkInt("table full of RSSI-only rows", acabMarkListedMacs(&gT), CAP);
    chkInt("  ^ holding 2 observations each", acabMarkListedObs(&gT), CAP * 2);
    chkInt("  ^ nothing lost yet", gT.otherObs, 0);
    chkTrue("accounted", acabMarkAccounted(&gT));

    note(0x99, -80, 0x01, false, 2100);       // WEAK but vendor-confirmed: must still get in
    chkTrue("a vendor-confirmed device evicts an RSSI-only row even when weaker",
            acabMarkListedMacs(&gT) == CAP && gRec[0].vendorMask + gRec[1].vendorMask +
            gRec[2].vendorMask + gRec[3].vendorMask == 0x01);
    // THE REGRESSION THIS FILE EXISTS FOR: the evicted row held n=2, and those two observations
    // must reappear in other_obs rather than vanishing into a summary that still looks complete.
    chkInt("  ^ the evicted row's 2 observations moved to other_obs", gT.otherObs, 2);
    chkInt("  ^ total_obs unchanged by where the row went", gT.totalObs, CAP * 2 + 1);
    chkTrue("accounted after eviction", acabMarkAccounted(&gT));

    printf("\n-- a table full of PROTECTED rows drops, and says so --\n");
    acabMarkReset(&gT, 3000);
    for (uint8_t i = 0; i < CAP; i++) note((uint8_t)(0x20 + i), -50, 0x02, false, 3000);
    chkInt("every slot now holds a vendor-confirmed device", acabMarkListedMacs(&gT), CAP);
    note(0x99, -50, 0x04, false, 3100);       // nothing evictable: all rows are protected
    chkInt("  ^ the new evidence-bearing device is dropped", acabMarkListedMacs(&gT), CAP);
    chkInt("  ^ and full_obs records it", gT.fullObs, 1);
    chkInt("  ^ other_obs untouched: nothing was evicted", gT.otherObs, 0);
    chkTrue("accounted when full", acabMarkAccounted(&gT));

    printf("\n-- solicitation protects a row without being vendor confirmation --\n");
    acabMarkReset(&gT, 4000);
    { uint8_t m[6]; mac6(m, 0x30);
      acabMarkNote(&gT, m, -90, "", 0x00, 0x01, false, 0xFF, 4000, -70); }
    chkInt("a weak solicit-only device still earns a row", acabMarkListedMacs(&gT), 1);
    chkInt("  ^ recorded as solicitation", gRec[0].solicitMask, 0x01);
    chkInt("  ^ and NOT as vendor confirmation", gRec[0].vendorMask, 0x00);
    chkTrue("accounted", acabMarkAccounted(&gT));

    printf("\n-- a closed window ignores everything --\n");
    gT.open = false;
    const uint32_t before = gT.totalObs;
    note(0x40, -30, 0x01, true, 5000);
    chkInt("no observation is counted while closed", gT.totalObs, before);

    printf("\n-- the invariant holds under a churn that mixes every path --\n");
    acabMarkReset(&gT, 6000);
    for (uint32_t i = 0; i < 400; i++) {
        const uint8_t last = (uint8_t)(i % 37);                 // more MACs than slots
        const int rssi = (i % 3 == 0) ? -95 : -45;              // some too weak to list
        const uint8_t vm = (i % 11 == 0) ? 0x01 : 0x00;         // some evidence-bearing
        note(last, rssi, vm, (i % 23 == 0), 6000 + i);
    }
    chkTrue("accounted after 400 mixed observations", acabMarkAccounted(&gT));
    chkInt("  ^ listed_obs + other + full == total",
           (long)(acabMarkListedObs(&gT) + gT.otherObs + gT.fullObs), (long)gT.totalObs);
    chkTrue("  ^ and rows never exceed capacity", acabMarkListedMacs(&gT) <= CAP);

    printf("\n  %s (%d failure%s)\n\n", failures ? "REGRESSION DETECTED" : "all good",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
