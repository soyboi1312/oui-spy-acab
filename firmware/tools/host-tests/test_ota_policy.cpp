#include "../../lib/acab_core/ota_policy.h"
#include <cstdio>

static int fail = 0, run = 0;
static void chk(const char* name, bool got, bool want) {
    run++;
    if (got != want) fail++;
    printf("  %-62s %s\n", name, got == want ? "PASS" : "**FAIL**");
}

int main() {
    printf("\n=== authenticated OTA policy ===\n");
    const uint32_t v204 = acabOtaVersionPack("2.0.4");
    const uint32_t v205 = acabOtaVersionPack("2.0.5");
    const uint32_t v203 = acabOtaVersionPack("2.0.3");
    chk("signed newer image matching declaration is accepted",
        acabOtaAuthenticatedVersionAllowed(v205, v205, v204, v204, false), true);
    chk("signed image cannot differ from client declaration",
        acabOtaAuthenticatedVersionAllowed(v205, v204, v204, v204, false), false);
    chk("normal flow rejects same version",
        acabOtaAuthenticatedVersionAllowed(v204, v204, v204, v203, false), false);
    chk("force permits same version recovery",
        acabOtaAuthenticatedVersionAllowed(v204, v204, v204, v203, true), true);
    chk("force never permits a downgrade",
        acabOtaAuthenticatedVersionAllowed(v203, v203, v204, v203, true), false);
    chk("confirmed floor rejects an older signed build",
        acabOtaAuthenticatedVersionAllowed(v204, v204, v203, v205, true), false);
    chk("unstamped version fails closed",
        acabOtaAuthenticatedVersionAllowed(v205, 0, v204, v204, false), false);

    // Fields have 10 bits. An out-of-range field used to SATURATE at 1023, which aliased distinct
    // versions (2.0.1023 == 2.0.5000) and, because the gates require strictly-newer, permanently
    // blocked upgrades past a saturated field. It now packs to 0 = malformed, which every caller
    // hard-rejects, and the boundary values still order correctly.
    chk("a field past 1023 packs as malformed (0), not saturated",
        acabOtaVersionPack("2.0.1024") == 0 && acabOtaVersionPack("2.0.5000") == 0
            && acabOtaVersionPack("9999.0.0") == 0, true);
    chk("field boundary 1023 still packs and orders",
        acabOtaVersionPack("2.0.1023") != 0
            && acabOtaVersionPack("2.0.1023") > acabOtaVersionPack("2.0.1022")
            && acabOtaVersionPack("2.1.0")   > acabOtaVersionPack("2.0.1023"), true);
    chk("a malformed (overflowing) version is refused by the gate",
        acabOtaAuthenticatedVersionAllowed(acabOtaVersionPack("2.0.5000"),
                                           acabOtaVersionPack("2.0.5000"), v204, v203, false), false);

    chk("signed image project identity matches exact running product",
        acabOtaProjectMatches("beacon board rev-B", "beacon board rev-B"), true);
    chk("rev-B signed image cannot cross onto rev-A",
        acabOtaProjectMatches("beacon board", "beacon board rev-B"), false);
    chk("empty project identity fails closed",
        acabOtaProjectMatches("beacon board", ""), false);

    chk("trial state applies to its exact running partition",
        acabOtaTrialMatches(0x330000, 0x330000), true);
    chk("stale prepared state does not condemn the old partition",
        acabOtaTrialMatches(0x10000, 0x330000), false);
    chk("missing target never counts as a trial",
        acabOtaTrialMatches(0x10000, 0), false);

    printf(fail ? "\n  REGRESSION (%d of %d)\n\n" : "\n  all good (0 failures of %d)\n\n",
           fail ? fail : run, fail ? run : 0);
    return fail ? 1 : 0;
}
