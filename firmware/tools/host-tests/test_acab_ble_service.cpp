/*
 * Host test: the STATUS-characteristic JSON length budget.
 *
 * WHY THIS EXISTS. acabBleUpdateStatus serializes into a fixed scratch buffer and stores the
 * result in the Status READ value. ArduinoJson truncates silently at the end of the buffer it is
 * given, and a frame that big can never notify (STATUS_JSON_MAX is above NOTIFY_MAX), so a
 * document that outgrew the builder used to be published as JSON cut mid-token on the ONE delivery
 * path left - and both apps drop unparseable JSON without a word. The firmware now refuses to
 * publish such a frame and keeps the last complete one; this test is the other half, the part that
 * makes an oversized document a BUILD failure rather than a field one.
 *
 * HOW IT WORKS, and why it is not a copy of the builder. The key set is read out of
 * acab_ble_service.cpp itself, so it cannot drift: every `doc["..."]` assignment inside
 * acabBleUpdateStatus is extracted from the source, and STATUS_JSON_MAX is read from the same
 * file. What this test owns is only the WIDTH each value may reach, one declared domain per key.
 * A newly added status key therefore fails here until someone writes down how wide it can get,
 * which is exactly the review that was missing.
 *
 * WHAT IT ASSERTS
 *   1. every emitted key has a declared width  (a new key stops the build)
 *   2. every declared width is still emitted    (a deleted key stops the build, so the budget
 *                                                below never quietly describes a document that
 *                                                no longer exists)
 *   3. the ALWAYS-ON document - the keys a healthy shipping dual-radio battery board emits on
 *      EVERY build, every counter at the top of its domain - is publishable. That is the floor:
 *      if it stopped fitting, the Status characteristic would be dead from the first build.
 *   4. the HEALTHY-REACHABLE document is publishable: pairing window open, LED switched off,
 *      buffer-all armed, a saturated ring, a wipe sweeping, an nRF DFU running and a charger
 *      attached, all at once, on a board with nothing wrong.
 *   5. the WORST CASE - the latched-flash-fault key on top of all of that - is publishable too.
 *      This is the HARD CEILING: every document the builder can produce, at the top of every
 *      declared domain, serializes strictly under STATUS_JSON_MAX, so the runtime overflow guard
 *      is defense in depth against a width this table missed, never an expected path.
 *
 * 4 and 5 were OVERAGE RATCHETS until 2026-08-26, because the healthy and worst-case documents
 * were then 21 and 53 bytes past the guard and a ceiling would only have hidden that debt. The
 * debt was paid the cross-platform way the old banner asked for: wseen, bseen and sdrop left the
 * periodic status for the {"diag":true} reply (verified first: NEITHER app parses any of the
 * three, and docs/ble-protocol.md's receipts contract reads them as start/end diagnostic deltas,
 * i.e. off that reply), "fw" was bounded by sizing fwbuf to its provable content, and "nrfv" was
 * clamped at the untrusted UART boundary. With every reachable document now fitting, a ceiling is
 * the honest assertion, and the moment ANY tier reaches the guard this build fails - the gap can
 * not silently reopen as a ratchet would have allowed.
 */
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// Declared value widths: the widest COMPACT JSON value each key can serialize to.
// booleans are 5 ("false"), a quoted string is its text plus 2, an integer is its digit count at
// the top of its domain. Where a domain is bounded by something outside this file, the bound is
// named so it can be re-checked.
// ---------------------------------------------------------------------------
// WHICH DOCUMENT A KEY BELONGS TO. This used to be one bit, `steady`, and one bit cannot say the
// thing that matters: ordinary states - an open pairing window, the LED switched off,
// buffer-all armed, a saturated ring, a wipe sweeping, an nRF DFU, a charger - were filed under
// the same "not steady" heading as a latched flash fault, which let the fitting assertion read as
// "a behaving board always publishes" while this very table said it might not. Three tiers, so
// each document the firmware can actually build gets measured as itself.
enum Tier {
    ALWAYS,    // emitted on every build on a healthy shipping dual-radio battery board
    HEALTHY,   // conditional, but reachable with NOTHING wrong: a user setting, a window, a normal op
    FAULT,     // reachable only once something has failed or been overrun
};

struct KeyBudget {
    const char* key;
    int         width;
    Tier        tier;
    const char* domain;
};

static const KeyBudget BUDGET[] = {
    // key         w  tier      domain
    { "fw",       34, ALWAYS,  "quoted; fwbuf is char[33], so at most 32 chars - and 32 is also the"
                               " content bound, not just the buffer: every label is <= 23 chars"
                               " (mesh-detect's fwLabel[24]; ACAB_FW_LABEL static_asserted at its"
                               " beacon-board use) and ACAB_FW_VERSION is static_asserted <= 8"
                               " beside fwbuf, so nothing truncates" },
    { "proto",     3, ALWAYS,  "ACAB_BLE_PROTO_VERSION, currently 2; 3 digits of headroom" },
    { "pairw",     3, HEALTHY, "ACAB_PAIR_WINDOW_MS / 1000 = 120 max; open for that long after"
                               " a deliberate power-on" },
    { "up",        7, ALWAYS,  "millis()/1000; millis wraps at 4294967 s" },
    { "total",    10, ALWAYS,  "uint32 counter, unbounded" },
    { "ble",       5, ALWAYS,  "bool" },
    { "wifi",      5, ALWAYS,  "bool" },
    { "wifiEco",   2, ALWAYS,  "0/3/7/15 s sweep sleep" },
    { "axon",      5, ALWAYS,  "bool" },
    { "moto",      5, ALWAYS,  "bool" },
    { "tracker",   5, ALWAYS,  "bool" },
    { "glasses",   5, ALWAYS,  "bool" },
    { "flock",     5, ALWAYS,  "bool" },
    { "drone",     5, ALWAYS,  "bool" },
    { "droui",     5, ALWAYS,  "bool" },
    { "ncam",      5, ALWAYS,  "bool" },
    { "buzzer",    5, ALWAYS,  "bool" },
    { "vol",       3, ALWAYS,  "alertsVolume() is uint8_t" },
    { "ledon",     5, HEALTHY, "emitted only as false; a user setting, not a fault" },
    { "gps",       5, ALWAYS,  "bool" },
    { "buf",       5, ALWAYS,  "detLogCount() <= gSlots; the shipped 1.5 MB ring is 24576 slots" },
    { "bufon",     5, ALWAYS,  "bool" },
    { "keymis",    4, HEALTHY, "emitted only as true for this authenticated session; absent=false" },
    { "bufall",    4, HEALTHY, "emitted only as true; a user opt-in" },
    { "bufsat",    4, HEALTHY, "emitted only as true; the expected end state of a long deploy" },
    { "buferr",    3, FAULT,   "DET_LOG_FAULT_* bitmask, 5 bits defined, so 31 max" },
    { "wiping",    4, HEALTHY, "emitted only as true; a wipe still sweeping - one the user asked"
                               " for, or the boot-count auto-wipe" },
    { "desert",    5, ALWAYS,  "bool" },
    { "ign",       3, ALWAYS,  "ignore list caps at 256" },
    { "wat",       3, ALWAYS,  "watchlist caps at 256" },
    // wseen / bseen / sdrop are NOT here because they are no longer in this document: they moved
    // to the {"diag":true} reply on 2026-08-26 (neither app parses them; the receipts contract
    // consumes them as start/end diagnostic deltas). Assertion 1 makes re-adding one a build
    // failure until its width is re-declared - and re-declaring it must find its bytes elsewhere,
    // because assertion 5 is now a hard ceiling.
    { "nbb",       5, ALWAYS,  "the nRF's ring caps at BB_SLOTS = 32768, but that bound lives on"
                               " the far side of the UART, so parseAdvLine saturates the D line's"
                               " value at 65535 to keep this width provable on THIS side" },
    { "bat",       3, ALWAYS,  "0..100, emitted only when >= 0" },
    { "co",        5, ALWAYS,  "bool" },
    { "nrfv",      4, ALWAYS,  "atoi of the nRF's V-line, an int off an untrusted UART - so it is"
                               " clamped to -1..9999 where it is parsed (parseAdvLine, beacon-board"
                               " main.cpp) AND re-capped at 9999 at the emit site in"
                               " acabBleUpdateStatus, which only emits >= 0; real domain is"
                               " NRF_APP_VERSION, currently 2" },
    { "rev",       3, ALWAYS,  "quoted \"A\" or \"B\"" },
    { "nrfup",     4, HEALTHY, "emitted only as true; a normal nRF OTA, not a fault" },
    { "chg",       4, HEALTHY, "emitted only as true; the board is on a charger" },
};
static const size_t BUDGET_N = sizeof(BUDGET) / sizeof(BUDGET[0]);

// There is deliberately NO overage allowance here any more. Until 2026-08-26 this file carried
// kHealthyOverBudget = 21 and kWorstOverBudget = 53 - ratchets recording how far past the guard
// the healthy and worst-case documents sat, because a ceiling would have hidden that debt. The
// debt is paid (see the banner for how), so every tier now asserts <= maxPublishable directly:
// a hard ceiling, correct precisely because there is no overage left for it to hide.

// ---------------------------------------------------------------------------
static int gFail = 0;
static void ok(const char* what, bool pass, const char* extra = "") {
    printf("  %-58s %s%s%s\n", what, pass ? "PASS" : "FAIL",
           extra[0] ? "  " : "", extra);
    if (!pass) gFail++;
}

static std::string slurp(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) return std::string();
    std::string s; char b[8192]; size_t n;
    while ((n = fread(b, 1, sizeof(b), f)) > 0) s.append(b, n);
    fclose(f);
    return s;
}

// Compact-JSON length of an object built from these keys: {"k":v,"k":v} .
static int docLen(const std::vector<const KeyBudget*>& keys) {
    if (keys.empty()) return 2;
    int n = 2 + (int)keys.size() - 1;                 // braces + separating commas
    for (const KeyBudget* k : keys) n += (int)strlen(k->key) + 3 + k->width;   // "key": + value
    return n;
}

int main() {
    printf("test_acab_ble_service: status + replay JSON budgets\n");

    // run.sh runs each binary from firmware/tools/host-tests.
    const char* kSrc = "../../lib/acab_core/acab_ble_service.cpp";
    std::string src = slurp(kSrc);
    if (src.empty()) {
        printf("  !! cannot read %s (run this from firmware/tools/host-tests)\n", kSrc);
        return 1;
    }
    const std::string scannerSrc = slurp("../../lib/acab_core/acab_scanner.cpp");
    const std::string detLogSrc = slurp("../../lib/acab_core/det_log.cpp");
    const std::string boardMain = slurp("../../src/beacon-board/main.cpp");
    if (scannerSrc.empty() || detLogSrc.empty() || boardMain.empty()) {
        printf("  !! cannot read scanner/det_log/beacon-board sources for lifecycle checks\n");
        return 1;
    }

    // The mesh build used to advertise before det_log's 24k-slot scan/config publication. A fast
    // reconnect could therefore enter the config callback against default startup state. Pin the
    // same initialization boundary beacon-board already uses.
    const char* kMeshMain = "../../src/mesh-detect/main.cpp";
    const std::string meshMain = slurp(kMeshMain);
    const size_t meshDetBegin = meshMain.find("detLogBegin();");
    const size_t meshAdvertise = meshMain.find("acabBleStartAdvertising();");
    ok("mesh initializes det_log before accepting BLE callbacks",
       meshDetBegin != std::string::npos && meshAdvertise != std::string::npos &&
       meshDetBegin < meshAdvertise);

    // STATUS_JSON_MAX, from the firmware rather than restated here.
    int cap = 0;
    {
        size_t p = src.find("STATUS_JSON_MAX = ");
        if (p == std::string::npos) { printf("  !! STATUS_JSON_MAX not found in %s\n", kSrc); return 1; }
        cap = atoi(src.c_str() + p + strlen("STATUS_JSON_MAX = "));
    }
    ok("STATUS_JSON_MAX parsed from the firmware", cap > 0);

    // Replay's final trim rung removes every variable-length field. Reconstruct its widest legal
    // compact JSON from the wire domains, then pin that independent calculation to the firmware's
    // constant and the iPhone-class 182-byte payload. This fails if a mandatory key is widened or
    // added without deliberately revisiting the guaranteed-minimal envelope.
    int replayWorstDeclared = 0;
    {
        size_t p = src.find("HIST_MIN_ENVELOPE_WORST = ");
        if (p == std::string::npos) {
            printf("  !! HIST_MIN_ENVELOPE_WORST not found in %s\n", kSrc); return 1;
        }
        replayWorstDeclared = atoi(src.c_str() + p + strlen("HIST_MIN_ENVELOPE_WORST = "));
    }
    // t=10, s=2 and meth=10 are the largest current enum wire values; confidence is 0..100,
    // RSSI int16, count uint16, seq reserves UINT32_MAX, and ms/boot span all uint32 values.
    static const char kReplayWorst[] =
        "{\"t\":10,\"s\":2,\"meth\":10,\"c\":100,\"mac\":\"ff:ff:ff:ff:ff:ff\"," 
        "\"rssi\":-32768,\"n\":65535,\"hist\":true,\"seq\":4294967294,\"approx\":true," 
        "\"ms\":4294967295,\"boot\":4294967295}";
    const int replayWorstComputed = (int)strlen(kReplayWorst);
    char replayNote[160];
    snprintf(replayNote, sizeof(replayNote), "%d B computed, %d B declared",
             replayWorstComputed, replayWorstDeclared);
    ok("minimal unanchored replay budget matches firmware declaration",
       replayWorstComputed == replayWorstDeclared, replayNote);
    snprintf(replayNote, sizeof(replayNote), "%d B, %d B spare under iPhone cap",
             replayWorstComputed, 182 - replayWorstComputed);
    ok("minimal replay envelope fits a 182-byte notify payload",
       replayWorstComputed <= 182, replayNote);
    ok("final replay rung removes the variable-length UAS id",
       src.find("trim >= HIST_TRIM_ID") != std::string::npos);

    // The storage cursor must advance after, never before, the host queue accepted the frame.
    // This is a source-level integration check because the BLE service itself depends on the
    // target-only NimBLE stack; det_log's real peek/commit behavior is exercised separately by
    // test_det_log.cpp.
    {
        const size_t drain = src.find("void acabBleDrainTick()");
        const size_t peek = drain == std::string::npos ? drain : src.find("detLogPeekForDrain(&r)", drain);
        const size_t queue = peek == std::string::npos ? peek : src.find("queueDetNotify(", peek);
        const size_t commit = queue == std::string::npos ? queue :
            src.find("detLogCommitDrain(r.seq, r.drainGeneration)", queue);
        const size_t count = commit == std::string::npos ? commit :
            src.find("gReplaySession.noteRecordCommitted(recordToken)", commit);
        ok("replay integrates peek -> successful host queue -> commit",
           drain != std::string::npos && peek != std::string::npos &&
           queue != std::string::npos && commit != std::string::npos && peek < queue && queue < commit);
        ok("replay count update follows the exact accepted commit",
           count != std::string::npos && commit < count);
        ok("replay queue helper observes NimBLE's enqueue return code",
           src.find("return ble_gatts_notify_custom(") != std::string::npos);

        // Cross-task integration half of test_replay_session.cpp. The pure state suite forces the
        // invalidation interleavings; these source assertions ensure the real BLE service actually
        // binds queue+commit+count to that state and invalidates every record-layer reset route.
        const size_t recordGuard = peek == std::string::npos ? peek :
            src.rfind("ReplayLock rl;", queue);
        ok("record prequeue check and queue run under ReplayLock",
           recordGuard != std::string::npos && recordGuard > peek && recordGuard < queue &&
           src.find("gReplaySession.mayQueueRecord(recordToken)", recordGuard) < queue);
        ok("queue, commit, and count stay inside one replay critical section",
           recordGuard != std::string::npos && recordGuard < queue && queue < commit && commit < count &&
           src.find("}", count) != std::string::npos);
        ok("every burst iteration revalidates current begin before peeking",
           src.find("for (int i = 0; i < DRAIN_BURST_MAX; i++)", drain) <
               src.find("gReplaySession.mayQueueRecord(recordToken)", drain) &&
           src.find("gReplaySession.mayQueueRecord(recordToken)", drain) < peek);
        ok("sync starts a fresh replay transport generation",
           src.find("startReplaySession(doc[\"sync\"].as<uint32_t>(), syncGeneration)") !=
               std::string::npos);
        const size_t replayStart = src.find("static void startReplaySession");
        ok("rejected keyless/unavailable sync cannot leave a transport session hanging",
           replayStart != std::string::npos &&
           src.find("result == DET_LOG_DRAIN_REJECTED", replayStart) != std::string::npos &&
           src.find("gReplaySession.invalidate();", replayStart) != std::string::npos);
        ok("accepted empty replay advances through begin(n=0) to end(n=0)",
           src.find("if (detLogDrainStartPending()) return;", drain) != std::string::npos &&
           src.find("stage == REPLAY_RECORD", drain) != std::string::npos &&
           src.find("gReplaySession.noteEndPending(stageToken);", drain) != std::string::npos);
        ok("sync carries an explicit durable log generation with safe legacy fallback",
           src.find("doc[\"syncgen\"].is<uint32_t>()") != std::string::npos &&
           src.find("? doc[\"syncgen\"].as<uint32_t>() : 0") != std::string::npos &&
           src.find("doc[\"gen\"]  = detLogGeneration();") != std::string::npos);
        ok("disconnect invalidates the complete replay transport session",
           src.find("stopReplaySession();", src.find("void onDisconnect")) != std::string::npos);
        const size_t disconnect = src.find("void onDisconnect");
        const size_t disconnectStop = disconnect == std::string::npos ? disconnect :
            src.find("stopReplaySession();", disconnect);
        const size_t disconnectKeyCleanup = disconnectStop == std::string::npos ? disconnectStop :
            src.find("detLogEndConfigSession();", disconnectStop);
        ok("disconnect always scrubs disabled-session keys after replay invalidation",
           disconnect != std::string::npos && disconnectStop != std::string::npos &&
           disconnectKeyCleanup != std::string::npos && disconnectStop < disconnectKeyCleanup &&
           src.find("if (scrubReplayKey)", disconnect) == std::string::npos);
        const size_t auth = src.find("void onAuthenticationComplete");
        const size_t connectLifecycle = src.find("void onConnect");
        const size_t connectOwnerGateClear = connectLifecycle == std::string::npos ?
            connectLifecycle : src.find("gOwnerCaptureBlocked = false;", connectLifecycle);
        ok("a failed away publication stays fail-closed across the next raw link",
           connectLifecycle != std::string::npos && auth != std::string::npos &&
           (connectOwnerGateClear == std::string::npos || connectOwnerGateClear > auth));
        const size_t privacyArm = auth == std::string::npos ? auth :
            src.find("gConfigPrivacyReady = detLogPrepareConfigSession();", auth);
        const size_t configAdmit = auth == std::string::npos ? auth :
            src.find("gConnected = true;", auth);
        ok("authenticated link pre-arms disabled privacy before config admission",
           auth != std::string::npos && privacyArm != std::string::npos &&
           configAdmit != std::string::npos && privacyArm < configAdmit);
        const size_t authenticatedGpsClear = auth == std::string::npos ? auth :
            src.find("clearPhoneGpsShadow(true);", auth);
        const size_t authGateRaise = auth == std::string::npos ? auth :
            src.find("gOwnerCaptureBlocked = true;", auth);
        const size_t authEpochBlock = authGateRaise == std::string::npos ? authGateRaise :
            src.find("acabScannerBlockCaptureForOwnerSession()", authGateRaise);
        const size_t authGateRelease = configAdmit == std::string::npos ? configAdmit :
            src.find("gOwnerCaptureBlocked = false;", configAdmit);
        const size_t authEpochAdmit = configAdmit == std::string::npos ? configAdmit :
            src.find("acabScannerAdmitCaptureForOwnerSession()", configAdmit);
        ok("authentication blocks owner-era appends before GPS and privacy preparation",
           authGateRaise != std::string::npos && authEpochBlock != std::string::npos &&
           authenticatedGpsClear != std::string::npos && privacyArm != std::string::npos &&
           authGateRaise < authEpochBlock && authEpochBlock < authenticatedGpsClear &&
           authenticatedGpsClear < privacyArm);
        ok("temporary auth gate admits its reserved epoch only after connected becomes true",
           configAdmit != std::string::npos && authEpochAdmit != std::string::npos &&
           authGateRelease != std::string::npos &&
           configAdmit < authEpochAdmit && authEpochAdmit < authGateRelease &&
           src.find("return gConnected || gOwnerCaptureBlocked;") != std::string::npos);
        const size_t gpsClearHelper = src.find("static void clearPhoneGpsShadow(bool includeRetained)");
        const size_t gpsClearLock = gpsClearHelper == std::string::npos ? gpsClearHelper :
            src.find("portENTER_CRITICAL(&gGpsMux);", gpsClearHelper);
        const size_t gpsClearLive = gpsClearLock == std::string::npos ? gpsClearLock :
            src.find("gPhoneLat = 0; gPhoneLon = 0; gPhoneGpsUs = 0; gPhoneGpsValid = false;",
                     gpsClearLock);
        const size_t gpsClearRetained = gpsClearLive == std::string::npos ? gpsClearLive :
            src.find("gLastPhoneGpsUs = 0; gLastPhoneGpsValid = false;", gpsClearLive);
        const size_t gpsClearUnlock = gpsClearRetained == std::string::npos ? gpsClearRetained :
            src.find("portEXIT_CRITICAL(&gGpsMux);", gpsClearRetained);
        const size_t retainedGetter = src.find("bool acabBleGetLastPhoneGps");
        ok("every authenticated peer clears current and retained GPS before config admission",
           authenticatedGpsClear != std::string::npos && authenticatedGpsClear < privacyArm &&
           gpsClearLock != std::string::npos && gpsClearLive < gpsClearRetained &&
           gpsClearRetained < gpsClearUnlock &&
           src.find("const bool valid = gLastPhoneGpsValid;", retainedGetter) != std::string::npos);
        const size_t disconnectGateRaise = disconnect == std::string::npos ? disconnect :
            src.find("gOwnerCaptureBlocked = true;", disconnect);
        const size_t disconnectBlock = disconnectGateRaise == std::string::npos ?
            disconnectGateRaise : src.find("acabScannerBlockCaptureForOwnerSession()",
                                            disconnectGateRaise);
        const size_t disconnectPublish = disconnect == std::string::npos ? disconnect :
            src.find("gConnected = false;", disconnect);
        const size_t disconnectGpsClear = disconnect == std::string::npos ? disconnect :
            src.find("clearPhoneGpsShadow(!retainGpsForAwayRows);", disconnect);
        const size_t disconnectRearm = disconnectKeyCleanup == std::string::npos ?
            disconnectKeyCleanup :
            src.find("acabScannerReArmCapture(&gOwnerCaptureBlocked)", disconnectKeyCleanup);
        ok("disconnect retains GPS only for a session accepted by the current log generation",
           disconnectGpsClear != std::string::npos &&
           src.find("const bool retainGpsForAwayRows = gSessionReplayKeySupplied;", disconnect) <
               disconnectGpsClear);
        ok("known phone B cannot inherit known phone A's retained GPS without a new fix",
           authenticatedGpsClear != std::string::npos &&
           src.find("if (!gPeerKnownAtConnect) clearPhoneGpsShadow(true);") == std::string::npos &&
           authenticatedGpsClear < privacyArm && privacyArm < configAdmit);
        ok("disconnect blocks claims before state teardown and publishes away capture last",
           disconnectGateRaise != std::string::npos && disconnectBlock != std::string::npos &&
           disconnectPublish != std::string::npos && disconnectGpsClear != std::string::npos &&
           disconnectStop != std::string::npos && disconnectKeyCleanup != std::string::npos &&
           disconnectRearm != std::string::npos &&
           disconnectGateRaise < disconnectBlock && disconnectBlock < disconnectPublish &&
           disconnectPublish < disconnectGpsClear && disconnectGpsClear < disconnectStop &&
           disconnectStop < disconnectKeyCleanup && disconnectKeyCleanup < disconnectRearm);
        const size_t scannerDisconnectFinish = scannerSrc.find(
            "bool acabScannerReArmCapture(volatile bool* ownerCaptureBlocked)");
        const size_t disconnectPendingAdmit = scannerDisconnectFinish == std::string::npos ?
            scannerDisconnectFinish :
            scannerSrc.find("detLogAdmitCaptureForOwnerSession(pending)",
                            scannerDisconnectFinish);
        const size_t disconnectGenPublish = disconnectPendingAdmit == std::string::npos ?
            disconnectPendingAdmit : scannerSrc.find("gCaptureGen++;", disconnectPendingAdmit);
        const size_t disconnectEpochPublish = disconnectGenPublish == std::string::npos ?
            disconnectGenPublish :
            scannerSrc.find("gAdmissionEpoch = nextAdmissionEpoch;", disconnectGenPublish);
        const size_t disconnectGateRelease = disconnectEpochPublish == std::string::npos ?
            disconnectEpochPublish :
            scannerSrc.find("*ownerCaptureBlocked = false;", disconnectEpochPublish);
        const size_t disconnectPublishUnlock = disconnectGateRelease == std::string::npos ?
            disconnectGateRelease :
            scannerSrc.find("portEXIT_CRITICAL(&gDedupMux);", disconnectGateRelease);
        ok("disconnect-window claim cannot consume the newly published away generation",
           scannerDisconnectFinish != std::string::npos &&
           disconnectPendingAdmit != std::string::npos &&
           disconnectGenPublish != std::string::npos &&
           disconnectEpochPublish != std::string::npos &&
           disconnectGateRelease != std::string::npos &&
           disconnectPublishUnlock != std::string::npos &&
           disconnectPendingAdmit < disconnectGenPublish &&
           disconnectGenPublish < disconnectEpochPublish &&
           disconnectEpochPublish < disconnectGateRelease &&
           disconnectGateRelease < disconnectPublishUnlock &&
           scannerSrc.find("if (nextAdmissionEpoch != 0)", disconnectEpochPublish) <
               disconnectGateRelease);
        const size_t scannerAppend = scannerSrc.find(
            "detLogAppendClaimed(it.d, &it.bufGps, it.claim.admissionEpoch)");
        const size_t authEpochAdvance = scannerSrc.find(
            "detLogBlockCaptureForOwnerSession();");
        const size_t authEpochZero = authEpochAdvance == std::string::npos ? authEpochAdvance :
            scannerSrc.find("gAdmissionEpoch = 0;", authEpochAdvance);
        const size_t scannerEpochAdmit = scannerSrc.find(
            "bool acabScannerAdmitCaptureForOwnerSession()");
        const size_t detEpochAdmit = scannerEpochAdmit == std::string::npos ? scannerEpochAdmit :
            scannerSrc.find("detLogAdmitCaptureForOwnerSession(pending)", scannerEpochAdmit);
        const size_t admittedEpochPublish = detEpochAdmit == std::string::npos ? detEpochAdmit :
            scannerSrc.find("gAdmissionEpoch = pending;", detEpochAdmit);
        const size_t epochAdvance = scannerSrc.find("detLogAdvanceCaptureEpoch();");
        const size_t epochPublish = scannerSrc.find(
            "gAdmissionEpoch = nextAdmissionEpoch;", epochAdvance);
        const size_t appendConnectedCheck = detLogSrc.find(
            "gCaptureAdmissionBlocked || acabBleClientConnected()");
        const size_t appendEpochGuard = detLogSrc.find(
            "enforceCaptureEpoch && captureEpoch", appendConnectedCheck);
        const size_t appendEpochCheck = appendEpochGuard == std::string::npos ? appendEpochGuard :
            detLogSrc.find("captureEpoch != gCaptureAdmissionEpoch", appendEpochGuard);
        ok("backlogged prior-owner claim is checked at det_log's locked append boundary",
           scannerAppend != std::string::npos && authEpochAdvance != std::string::npos &&
           authEpochZero != std::string::npos && authEpochAdvance < authEpochZero &&
           scannerEpochAdmit != std::string::npos && detEpochAdmit != std::string::npos &&
           admittedEpochPublish != std::string::npos && detEpochAdmit < admittedEpochPublish &&
           epochAdvance != std::string::npos &&
           epochPublish != std::string::npos && epochAdvance < epochPublish &&
           appendConnectedCheck != std::string::npos && appendEpochGuard != std::string::npos &&
           appendEpochCheck != std::string::npos && appendConnectedCheck < appendEpochGuard &&
           appendEpochGuard < appendEpochCheck);
        const size_t guardedDelivery = scannerSrc.find(
            "detLogDeliverIfCaptureEpochCurrent(it.claim.admissionEpoch");
        const size_t directDelivery = scannerSrc.find("if (it.deliver && gSink) gSink(");
        const size_t replayBranch = scannerSrc.find("if (isReplay)");
        const size_t replayEpochStamp = replayBranch == std::string::npos ? replayBranch :
            scannerSrc.find("it.claim.admissionEpoch = gAdmissionEpoch;", replayBranch);
        ok("every queued sink delivery, including nRF replay, is owner-epoch guarded",
           guardedDelivery != std::string::npos && directDelivery == std::string::npos &&
           replayEpochStamp != std::string::npos);
        const size_t deliveryGuard = detLogSrc.find(
            "bool detLogDeliverIfCaptureEpochCurrent");
        const size_t deliveryOwnerLock = deliveryGuard == std::string::npos ? deliveryGuard :
            detLogSrc.find("captureDeliveryLock()", deliveryGuard);
        const size_t deliveryIoUnlock = deliveryOwnerLock == std::string::npos ? deliveryOwnerLock :
            detLogSrc.find("ioUnlock();", deliveryOwnerLock);
        const size_t deliveryCallback = deliveryIoUnlock == std::string::npos ? deliveryIoUnlock :
            detLogSrc.find("deliver(context);", deliveryIoUnlock);
        const size_t deliveryOwnerUnlock = deliveryCallback == std::string::npos ? deliveryCallback :
            detLogSrc.find("captureDeliveryUnlock();", deliveryCallback);
        ok("delivery serializes owner handoff without holding det_log flash lock through BLE JSON",
           deliveryOwnerLock != std::string::npos && deliveryIoUnlock != std::string::npos &&
           deliveryCallback != std::string::npos && deliveryOwnerUnlock != std::string::npos &&
           deliveryOwnerLock < deliveryIoUnlock && deliveryIoUnlock < deliveryCallback &&
           deliveryCallback < deliveryOwnerUnlock);
        const size_t cadenceHelper = scannerSrc.find("static void rearmCaptureCadenceOnly()");
        const size_t bufferAllTick = scannerSrc.find("void acabScannerBufferAllTick()");
        const size_t cadenceCall = bufferAllTick == std::string::npos ? bufferAllTick :
            scannerSrc.find("rearmCaptureCadenceOnly();", bufferAllTick);
        const size_t cadenceEpochAdvance = cadenceHelper == std::string::npos ? cadenceHelper :
            scannerSrc.find("detLogAdvanceCaptureEpoch();", cadenceHelper);
        ok("periodic capture rearm leaves owner admission epoch unchanged",
           cadenceHelper != std::string::npos && bufferAllTick != std::string::npos &&
           cadenceCall != std::string::npos &&
           (cadenceEpochAdvance == std::string::npos || cadenceEpochAdvance > bufferAllTick));
        const size_t cfgWrite = src.find("class CfgCb");
        const size_t cfgGuard = cfgWrite == std::string::npos ? cfgWrite :
            src.find("if (!gConnected || !gConfigPrivacyReady || !c) return;", cfgWrite);
        const size_t cfgCopy = cfgGuard == std::string::npos ? cfgGuard :
            src.find("std::string v = c->getValue();", cfgGuard);
        ok("denied config links return before copying or parsing writes",
           cfgWrite != std::string::npos && cfgGuard != std::string::npos &&
           cfgCopy != std::string::npos && cfgGuard < cfgCopy);
        ok("unconditional disconnect scrub performs no disable/NVS generation transition",
           disconnectKeyCleanup != std::string::npos &&
           src.find("if (!detLogEnabled()) detLogSetEnabled(false);") == std::string::npos);
        const size_t keyInstall = src.find(
            "installReplayKey(k, gSessionKeyReplacementApproved)");
        const size_t keyZero = keyInstall == std::string::npos ? keyInstall :
            src.find("zeroSecret(k, sizeof(k));", keyInstall);
        ok("config callback explicitly zeroizes its decoded key buffer",
           keyInstall != std::string::npos && keyZero != std::string::npos && keyInstall < keyZero);
        ok("clear, key install, and disable use replay-invalidating wrappers",
           src.find("clearReplayLog();") != std::string::npos &&
           keyInstall != std::string::npos &&
           src.find("else disableReplayLog();") != std::string::npos);
        const size_t keyResult = src.find("const DetLogKeyResult keyResult");
        const size_t keySessionReady = keyResult == std::string::npos ? keyResult :
            src.find("gSessionReplayKeySupplied = keyResult == DET_LOG_KEY_ACCEPTED;", keyResult);
        const size_t syncBranch = src.find("if (doc[\"sync\"].is<uint32_t>())");
        const size_t syncKeyGate = syncBranch == std::string::npos ? syncBranch :
            src.find("if (!gSessionReplayKeySupplied)", syncBranch);
        const size_t gatedReplayStart = syncKeyGate == std::string::npos ? syncKeyGate :
            src.find("startReplaySession(doc[\"sync\"].as<uint32_t>(), syncGeneration);",
                     syncKeyGate);
        ok("sync requires a det_log-accepted key from this authenticated session",
           keyResult != std::string::npos && keySessionReady != std::string::npos &&
           syncKeyGate != std::string::npos && gatedReplayStart != std::string::npos &&
           keyResult < keySessionReady && syncKeyGate < gatedReplayStart);
        const size_t mismatchGpsClear = keyResult == std::string::npos ? keyResult :
            src.find("clearPhoneGpsShadow(true);", keyResult);
        ok("mismatched/no-key owner location cannot enter the retained key generation",
           mismatchGpsClear != std::string::npos &&
           src.find("if (keyResult == DET_LOG_KEY_MISMATCH)", keyResult) < mismatchGpsClear &&
           disconnectGpsClear != std::string::npos);
        ok("accepted-then-mismatched disabled session still scrubs its accepted RAM key",
           keySessionReady != std::string::npos && disconnectKeyCleanup != std::string::npos &&
           src.find("if (scrubReplayKey)", disconnect) == std::string::npos);
        const size_t explicitClear = cfgWrite == std::string::npos ? cfgWrite :
            src.find("if (doc[\"clearlog\"].is<bool>()", cfgWrite);
        const size_t configKey = cfgWrite == std::string::npos ? cfgWrite :
            src.find("if (doc[\"key\"].is<const char*>())", cfgWrite);
        const size_t replacementConsume = keyResult == std::string::npos ? keyResult :
            src.find("if (keyResult == DET_LOG_KEY_ACCEPTED)", keyResult);
        const size_t connect = src.find("void onConnect");
        const size_t replacementResetOnConnect = connect == std::string::npos ? connect :
            src.find("gSessionKeyReplacementApproved = false;", connect);
        const size_t replacementResetOnDisconnect = disconnect == std::string::npos ? disconnect :
            src.find("gSessionKeyReplacementApproved = false;", disconnect);
        ok("only explicit clear authorizes replacement and is processed before its key",
           explicitClear != std::string::npos && configKey != std::string::npos &&
           explicitClear < configKey &&
           src.find("gSessionKeyReplacementApproved = true;", explicitClear) < configKey &&
           replacementConsume != std::string::npos &&
           src.find("gSessionKeyReplacementApproved = false;", replacementConsume) !=
               std::string::npos &&
           replacementResetOnConnect != std::string::npos &&
           replacementResetOnDisconnect != std::string::npos);
        ok("key mismatch is session-only status and every authentication rebuilds stale value",
           src.find("gSessionKeyMismatch = keyResult == DET_LOG_KEY_MISMATCH;") !=
               std::string::npos &&
           src.find("if (gSessionKeyMismatch) doc[\"keymis\"] = true;") !=
               std::string::npos &&
           src.find("acabBleUpdateStatus();", configAdmit) != std::string::npos);
        const size_t requestTokenAdvance = src.find("static void advanceLinkSessionToken()");
        const size_t connectTokenAdvance = connect == std::string::npos ? connect :
            src.find("advanceLinkSessionToken();", connect);
        const size_t disconnectTokenAdvance = disconnect == std::string::npos ? disconnect :
            src.find("advanceLinkSessionToken();", disconnect);
        const size_t leaseInit = src.find("gLinkActions.initialize()");
        const size_t leaseAdvance = requestTokenAdvance == std::string::npos ?
            requestTokenAdvance : src.find("gLinkActions.advance()", requestTokenAdvance);
        const size_t nrfRun = src.find("bool acabBleRunNrfDfuRequest(");
        const size_t nrfLeaseRun = nrfRun == std::string::npos ? nrfRun :
            src.find("gLinkActions.run(", nrfRun);
        const size_t nrfRequest = cfgWrite == std::string::npos ? cfgWrite :
            src.find("gLinkActions.arm(AcabLinkActionSlot::nrfDfu)", cfgWrite);
        const size_t powerRequest = cfgWrite == std::string::npos ? cfgWrite :
            src.find("gLinkActions.arm(AcabLinkActionSlot::powerOff)", cfgWrite);
        const size_t powerRun = src.find("bool acabBleRunPowerOffRequest(");
        const size_t powerLeaseRun = powerRun == std::string::npos ? powerRun :
            src.find("gLinkActions.run(AcabLinkActionSlot::powerOff", powerRun);
        const size_t boardNrfCallback = boardMain.find("static void runRequestedNrfDfu(void*)");
        const size_t boardNrfAction = boardNrfCallback == std::string::npos ? boardNrfCallback :
            boardMain.find("nrfEnterDfu();", boardNrfCallback);
        const size_t boardNrfLease = boardMain.find(
            "acabBleRunNrfDfuRequest(runRequestedNrfDfu)");
        const size_t boardPowerCallback = boardMain.find("static void runRequestedPowerOff(void*)");
        const size_t boardPowerAction = boardPowerCallback == std::string::npos ?
            boardPowerCallback : boardMain.find("powerOffDeepSleep(true);", boardPowerCallback);
        const size_t boardPowerLease = boardMain.find(
            "acabBleRunPowerOffRequest(runRequestedPowerOff)");
        ok("delayed DFU check and physical action share the link-boundary lease",
           requestTokenAdvance != std::string::npos && connectTokenAdvance != std::string::npos &&
           disconnectTokenAdvance != std::string::npos && leaseInit != std::string::npos &&
           leaseAdvance != std::string::npos && nrfRequest != std::string::npos &&
           nrfLeaseRun != std::string::npos && boardNrfCallback != std::string::npos &&
           boardNrfAction != std::string::npos && boardNrfLease != std::string::npos &&
           boardNrfCallback < boardNrfAction && boardNrfAction < boardNrfLease &&
           src.find("acabBleTakeNrfDfuRequest") == std::string::npos);
        ok("delayed power-off action also executes inside the owner lease",
           powerRequest != std::string::npos && powerLeaseRun != std::string::npos &&
           boardPowerCallback != std::string::npos && boardPowerAction != std::string::npos &&
           boardPowerLease != std::string::npos &&
           boardPowerCallback < boardPowerAction && boardPowerAction < boardPowerLease &&
           src.find("acabBleTakePowerOffRequest") == std::string::npos);
        ok("legacy loose replay envelope globals are gone",
           src.find("gHistSent") == std::string::npos &&
           src.find("gHistBeginSent") == std::string::npos &&
           src.find("gHistEndPending") == std::string::npos);
    }

    // Every doc["..."] inside acabBleUpdateStatus, comments stripped so a key merely MENTIONED in
    // prose is not counted as emitted.
    std::vector<std::string> emitted;
    {
        size_t a = src.find("void acabBleUpdateStatus()");
        size_t b = a == std::string::npos ? a : src.find("len = serializeJson(", a);
        if (a == std::string::npos || b == std::string::npos) {
            printf("  !! could not bound acabBleUpdateStatus in %s\n", kSrc); return 1;
        }
        std::string body = src.substr(a, b - a);
        size_t line = 0;
        while (line < body.size()) {
            size_t eol = body.find('\n', line);
            if (eol == std::string::npos) eol = body.size();
            std::string code = body.substr(line, eol - line);
            size_t c = code.find("//");
            if (c != std::string::npos) code = code.substr(0, c);
            size_t p = 0;
            while ((p = code.find("doc[\"", p)) != std::string::npos) {
                size_t q = code.find("\"]", p + 5);
                if (q == std::string::npos) break;
                std::string k = code.substr(p + 5, q - (p + 5));
                bool seen = false;
                for (const std::string& e : emitted) if (e == k) { seen = true; break; }
                if (!seen) emitted.push_back(k);
                p = q + 2;
            }
            line = eol + 1;
        }
    }
    ok("status keys extracted from acabBleUpdateStatus", !emitted.empty());

    // 1. every emitted key has a declared width.
    for (const std::string& k : emitted) {
        bool found = false;
        for (size_t i = 0; i < BUDGET_N; i++) if (k == BUDGET[i].key) { found = true; break; }
        if (!found) {
            char msg[160];
            snprintf(msg, sizeof(msg), "new status key \"%s\" has no declared width", k.c_str());
            ok(msg, false, "add it to BUDGET with the widest value it can serialize to");
        }
    }
    if (gFail == 0) ok("every emitted key has a declared width", true);

    // 2. every declared width is still emitted.
    for (size_t i = 0; i < BUDGET_N; i++) {
        bool found = false;
        for (const std::string& k : emitted) if (k == BUDGET[i].key) { found = true; break; }
        if (!found) {
            char msg[160];
            snprintf(msg, sizeof(msg), "BUDGET lists \"%s\", which is no longer emitted", BUDGET[i].key);
            ok(msg, false, "drop the row so the budget describes the real document");
        }
    }

    // 3 + 4 + 5. Build the three documents from the DECLARED order-independent key set. Order does
    // not change a compact JSON length, so the sums below hold whatever order the builder emits in.
    std::vector<const KeyBudget*> all, always, healthy;
    for (size_t i = 0; i < BUDGET_N; i++) {
        all.push_back(&BUDGET[i]);
        if (BUDGET[i].tier == ALWAYS)  { always.push_back(&BUDGET[i]); healthy.push_back(&BUDGET[i]); }
        if (BUDGET[i].tier == HEALTHY) { healthy.push_back(&BUDGET[i]); }
    }
    const int alwaysLen  = docLen(always);
    const int healthyLen = docLen(healthy);
    const int worstLen   = docLen(all);

    // The largest frame that can actually be PUBLISHED. The guard rejects `len >= STATUS_JSON_MAX`
    // rather than `> `, because the scratch is declared one byte larger so truncation is
    // detectable, and a document that reaches the cap is indistinguishable from one cut mid-token.
    // So the last publishable length is cap - 1, and measuring against `cap` would quietly grant a
    // byte the firmware will not accept.
    const int maxPublishable = cap - 1;

    char note[200];
    snprintf(note, sizeof(note), "%d B, %d B spare under the %d B guard",
             alwaysLen, maxPublishable - alwaysLen, cap);
    ok("always-on status is publishable", alwaysLen <= maxPublishable, note);

    snprintf(note, sizeof(note), "%d B, %d B spare under the %d B guard",
             healthyLen, maxPublishable - healthyLen, cap);
    ok("healthy-board status is publishable", healthyLen <= maxPublishable, note);

    // THE HARD CEILING (see the banner): the full document, every key at the top of its declared
    // domain, must serialize strictly under STATUS_JSON_MAX. This is what keeps the 2026-08-26
    // recovery from silently reopening - any new key, wider domain, or re-added counter that
    // pushes past the guard fails the build here instead of costing frames in the field.
    snprintf(note, sizeof(note), "%d B, %d B spare under the %d B guard",
             worstLen, maxPublishable - worstLen, cap);
    ok("worst case fits STRICTLY under STATUS_JSON_MAX", worstLen <= maxPublishable, note);

    // Not assertions: the three tiers side by side, so a review can see how much of the guard
    // each reachable document actually uses.
    printf("\n  publishable ceiling %d B (STATUS_JSON_MAX %d; the guard drops a frame that reaches it)\n",
           maxPublishable, cap);
    printf("    always-on  %4d B  %s\n", alwaysLen,
           alwaysLen <= maxPublishable ? "fits" : "OVER - the Status characteristic never publishes");
    printf("    healthy    %4d B  %s\n", healthyLen,
           healthyLen <= maxPublishable ? "fits"
                       : "OVER - a board with nothing wrong freezes at its last good frame");
    printf("    worst case %4d B  %s\n", worstLen,
           worstLen <= maxPublishable
                     ? "fits - every reachable document publishes and the guard is belt and braces"
                     : "OVER - the hard ceiling is breached; shrink a domain or move a key to the"
                       " diag reply");

    printf("\n  %s\n", gFail ? "FAILURES" : "all good (0 failures)");
    return gFail ? 1 : 0;
}
