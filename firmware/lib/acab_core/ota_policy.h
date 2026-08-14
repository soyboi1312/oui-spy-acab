/* Pure OTA policy shared by production and host tests. */
#ifndef ACAB_OTA_POLICY_H
#define ACAB_OTA_POLICY_H

#include <stdint.h>
#include <string.h>

// "a.b.c" to a packed comparable value. A suffix is ignored; each field gets 10 bits. A field
// past 1023 returns 0 (= malformed, every caller hard-rejects) instead of saturating: saturation
// would alias 2.0.1023 with 2.0.5000, and because the upgrade gates require strictly-newer, a
// board that ever confirmed a saturated field could then never move past it. Fail loud, not close.
inline uint32_t acabOtaVersionPack(const char* s) {
    uint32_t p[3] = {0, 0, 0};
    int i = 0;
    if (!s) return 0;
    while (*s && i < 3) {
        uint32_t v = 0;
        while (*s >= '0' && *s <= '9') {
            v = v * 10 + (uint32_t)(*s - '0');
            if (v > 1023) return 0;
            s++;
        }
        p[i++] = v;
        if (*s == '.') s++; else break;
    }
    return (p[0] << 20) | (p[1] << 10) | p[2];
}

// The client declaration is only an early UX gate. Commit depends on the version inside the
// signed image, requires it to equal that declaration, and never crosses the confirmed floor.
inline bool acabOtaAuthenticatedVersionAllowed(uint32_t declaredVersion,
                                                uint32_t authenticatedVersion,
                                                uint32_t runningVersion,
                                                uint32_t confirmedFloor,
                                                bool force) {
    if (authenticatedVersion == 0 || authenticatedVersion != declaredVersion) return false;
    if (authenticatedVersion < confirmedFloor) return false;
    return force ? authenticatedVersion >= runningVersion
                 : authenticatedVersion > runningVersion;
}

// Every signed ACAB product shares one OTA key. The authenticated project_name therefore has to
// match the running product exactly before a pending image may become the boot target.
inline bool acabOtaProjectMatches(const char* runningProject, const char* pendingProject) {
    return runningProject && pendingProject && runningProject[0] && pendingProject[0]
        && strcmp(runningProject, pendingProject) == 0;
}

// A prepared rollback record only governs the exact partition it was written for. If Update.end
// failed or power was lost before the boot-slot switch, the old running image must clear it rather
// than treating itself as the failed trial.
inline bool acabOtaTrialMatches(uint32_t runningAddress, uint32_t targetAddress) {
    return targetAddress != 0 && runningAddress == targetAddress;
}

#endif
