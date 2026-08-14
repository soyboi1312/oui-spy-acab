// Host regression test for the live-notify elision policy (detect_elide.h).
//
// WHY: a fully populated drone Remote ID record does not fit a 185-MTU link, and the old behaviour
// was to DROP the live notify entirely - silence on the exact link the alert travels. The record is
// now trimmed field by field until it fits. What has to be pinned is not "it fits" (that is
// arithmetic the firmware does at runtime) but the POLICY: which fields may go, in what order, and
// which may never go. Those are product decisions, and a silent reordering would change what a user
// sees on a small-MTU phone with nothing failing.
#include "../../lib/acab_core/detect_elide.h"
#include <cstdio>
#include <cstring>

static int gFail = 0, gRun = 0;
static void chk(const char* name, bool ok) {
    gRun++; if (!ok) gFail++;
    printf("  %-62s %s\n", name, ok ? "PASS" : "**FAIL**");
}

int main() {
    printf("\n=== live-notify field elision ===\n");

    // THE DOCUMENTED ORDER, asserted as a sequence rather than field by field. Company ID is first
    // on purpose (diagnostics, not alert content); operator position is
    // last on purpose: on a drone record it is the most useful thing a person can act on.
    static const AcabElidableField kOrder[] = {
        ACAB_FIELD_CID,  ACAB_FIELD_PALT, ACAB_FIELD_HGT, ACAB_FIELD_VSPD,
        ACAB_FIELD_SPD,  ACAB_FIELD_HDG,  ACAB_FIELD_STA, ACAB_FIELD_PILOT
    };
    const int n = (int)(sizeof(kOrder) / sizeof(kOrder[0]));

    // At level L, exactly the first L fields of the order are gone and the rest survive. This is
    // the whole contract in one loop: it catches a reorder, an off-by-one, and a field that drops
    // early or refuses to drop at all.
    bool orderOk = true;
    for (int level = 0; level <= ACAB_ELIDE_MAX; level++) {
        for (int i = 0; i < n; i++) {
            const bool wantKeep = (i >= level);
            if (acabElideKeeps(kOrder[i], (uint8_t)level) != wantKeep) {
                orderOk = false;
                printf("      level %d: %s expected %s\n", level, acabElideKey(kOrder[i]),
                       wantKeep ? "KEPT" : "dropped");
            }
        }
    }
    chk("every level drops exactly the first N fields of the documented order", orderOk);

    // Spot-checks that read as English, so a failure names the product decision it broke.
    chk("full record keeps the company ID", acabElideKeeps(ACAB_FIELD_CID, ACAB_ELIDE_NONE));
    chk("full record keeps operator altitude", acabElideKeeps(ACAB_FIELD_PALT, ACAB_ELIDE_NONE));
    chk("first squeeze gives up the COMPANY ID, nothing else",
        !acabElideKeeps(ACAB_FIELD_CID,  ACAB_ELIDE_CID) &&
         acabElideKeeps(ACAB_FIELD_PALT, ACAB_ELIDE_CID) &&
         acabElideKeeps(ACAB_FIELD_PILOT, ACAB_ELIDE_CID));
    chk("second squeeze gives up operator ALTITUDE, keeping the rest",
        !acabElideKeeps(ACAB_FIELD_PALT, ACAB_ELIDE_PALT) &&
         acabElideKeeps(ACAB_FIELD_HGT,  ACAB_ELIDE_PALT) &&
         acabElideKeeps(ACAB_FIELD_PILOT, ACAB_ELIDE_PALT));
    chk("operator POSITION survives every level until the last",
        acabElideKeeps(ACAB_FIELD_PILOT, ACAB_ELIDE_STA));
    chk("operator POSITION is what the last level gives up",
        !acabElideKeeps(ACAB_FIELD_PILOT, ACAB_ELIDE_PILOT));
    chk("at max elision nothing optional survives", [&]{
        for (int i = 0; i < n; i++) if (acabElideKeeps(kOrder[i], ACAB_ELIDE_MAX)) return false;
        return true;
    }());

    // The mandatory list must never intersect the elidable list. If someone adds a field to both,
    // a user-visible or parser-critical key becomes droppable and nothing else would catch it.
    size_t mn = 0;
    const char* const* mandatory = acabElideMandatoryKeys(&mn);
    bool disjoint = true;
    for (size_t m = 0; m < mn; m++)
        for (int i = 0; i < n; i++)
            if (strcmp(mandatory[m], acabElideKey(kOrder[i])) == 0) disjoint = false;
    chk("no mandatory key is also an elidable key", disjoint);

    // The fields a parser or a person depends on. Named explicitly so removing one from the
    // mandatory list fails here rather than in the field.
    const char* mustHave[] = {"t", "mac", "rssi", "c", "lat", "lon", "id", "name", "new"};
    bool allPresent = true;
    for (const char* want : mustHave) {
        bool found = false;
        for (size_t m = 0; m < mn; m++) if (strcmp(mandatory[m], want) == 0) found = true;
        if (!found) { allPresent = false; printf("      missing from mandatory: %s\n", want); }
    }
    chk("type/mac/rssi/confidence/lat/lon/uas-id/name/new are all mandatory", allPresent);

    // Out-of-range levels must not silently start keeping things again (a wrapped or garbage level
    // reading as "full record" would be the worst possible failure mode here).
    chk("a level past MAX keeps nothing optional", [&]{
        for (int i = 0; i < n; i++) if (acabElideKeeps(kOrder[i], 250)) return false;
        return true;
    }());

    printf(gFail ? "\n  REGRESSION DETECTED (%d of %d)\n\n" : "\n  all good (0 failures of %d)\n\n",
           gFail ? gFail : gRun, gFail ? gRun : 0);
    return gFail ? 1 : 0;
}
