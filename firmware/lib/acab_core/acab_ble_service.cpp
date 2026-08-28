/*
 * ACAB OUI-Spy - BLE GATT service implementation (NimBLE-Arduino 1.4 API).
 */
#include "acab_ble_service.h"
#include "axon_detect.h"
#include "police_detect.h"
#include "desert_detect.h"
#include "tracker_detect.h"
#include "glasses_detect.h"
#include "flock_detect.h"
#include "drone_detect.h"
#include "netcam_detect.h"
#include "acab_scanner.h"
#include "coredump_report.h"
#include "detect_elide.h"   // live-notify field elision order (small-MTU links)
#include "gps_age.h"        // 64-bit monotonic age; retained fixes must not revive at millis wrap
#include "pair_window.h"    // rollover-safe window comparison (host-tested)
#include "replay_session.h" // generation-bound begin/record/end transport state (host-tested)
#include "link_action_lease.h" // check->physical-action ownership across loop/host tasks
#include <atomic>
#include "det_log.h"
#include "ota_update.h"

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <ArduinoJson.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <string.h>
#include <Preferences.h>   // per-unit IRK persistence (see the privacy block in acabBleBegin)
#include <esp_random.h>
#include <esp_timer.h>

// ---- privacy build-configuration guard -------------------------------------------------------
// PROVEN ON HARDWARE 2026-08-01, and the reason this guard exists rather than a comment.
//
// NimBLEDevice::setOwnAddrType(BLE_OWN_ADDR_RPA_*) looks like it enables address privacy. On
// ESP32-S3 with the stock Arduino sdkconfig it does NOT: the ble_hs_pvcy_rpa_config() call inside
// it sits behind #if MYNEWT_VAL(BLE_HOST_BASED_PRIVACY), which resolves to
// CONFIG_BT_NIMBLE_HOST_BASED_PRIVACY, which is not defined. The call compiles away, the function
// sets a member variable, and the board advertises its fixed factory address forever while every
// line of source reads as though privacy is on.
//
// That is exactly what shipped in the first attempt at this: two consecutive boots printed the
// identical address e8:3d:c1:... (an Espressif OUI, i.e. the factory public address). Nothing in
// the build warned. A comment would not have caught it, because the code was already commented.
//
// So: asking for privacy without the stack support is now a BUILD FAILURE, not a silent no-op.
#if ACAB_BLE_PRIVACY && !(defined(CONFIG_BT_NIMBLE_HOST_BASED_PRIVACY) && CONFIG_BT_NIMBLE_HOST_BASED_PRIVACY)
#error "ACAB_BLE_PRIVACY=1 needs -DCONFIG_BT_NIMBLE_HOST_BASED_PRIVACY=1 in build_flags. \
Without it NimBLE compiles the RPA call away and the board advertises a FIXED address while \
appearing to be private. Add the flag to this env in platformio.ini, or set ACAB_BLE_PRIVACY=0."
#endif

// acab_core-internal loop pumps and hooks driven from acabBleDrainTick below (every build's
// loop() already calls it each pass): the det_log deferred-wipe chunker + drain-resume cursor
// (det_log.cpp) and the scanner's deferred nRF ignore-list mirror (acab_scanner.cpp). Kept out
// of the public headers - the mains never call these directly, this tick is their only driver.
void     detLogEraseTick();
bool     detLogWipePending();
uint32_t detLogDrainFrom();
void     acabScannerMirrorTick();

// ---- outgoing-JSON scratch pool (PERF-6) ----------------------------------------------------
// Every outgoing notify (detection, 5 s status, each drained record) used to heap-allocate and
// free a fresh ArduinoJson pool. That is a lot of malloc/free churn (and fragmentation risk) on
// the hot path. Route all of them through ONE fixed static byte pool via a custom ArduinoJson 7
// Allocator, so building a document does ZERO heap alloc/free.
//
// The pool is bump-allocated and reset before each document build; deallocate is a no-op (the
// whole pool is rewound at the next build). reallocate copies via a per-block size header so the
// pool can grow correctly. These builders run on DIFFERENT tasks (the scanner sink task, loop(),
// and the NimBLE host task all produce JSON), so a single shared pool needs mutual exclusion:
// gJsonMux serializes access. The lock is held only across the (microsecond-scale) build +
// serializeJson into a caller-owned char buffer, never across a BLE notify() call.
alignas(8) static uint8_t gJsonPoolBuf[4096];   // one 128-slot variant pool + strings, with margin
static SemaphoreHandle_t  gJsonMux = nullptr;

class BumpAllocator : public ArduinoJson::Allocator {
  public:
    BumpAllocator(uint8_t* buf, size_t cap) : buf_(buf), cap_(cap), off_(0) {}
    void reset() { off_ = 0; }
    void* allocate(size_t size) override {
        size_t need = kHdr + align8(size);
        if (off_ + need > cap_) return nullptr;      // pool exhausted -> ArduinoJson marks overflow
        uint8_t* base = buf_ + off_;
        *reinterpret_cast<size_t*>(base) = size;     // remember the block size for reallocate()
        off_ += need;
        return base + kHdr;
    }
    void deallocate(void*) override {}               // bulk-rewound in reset() before each build
    void* reallocate(void* ptr, size_t new_size) override {
        if (!ptr) return allocate(new_size);
        size_t old = *reinterpret_cast<size_t*>(static_cast<uint8_t*>(ptr) - kHdr);
        void* np = allocate(new_size);
        if (np && old) memcpy(np, ptr, old < new_size ? old : new_size);
        return np;
    }
  private:
    static size_t align8(size_t n) { return (n + 7) & ~size_t(7); }
    static const size_t kHdr = 8;                    // 8-byte, 8-aligned size header per block
    uint8_t* buf_; size_t cap_; size_t off_;
};
static BumpAllocator gJsonPool(gJsonPoolBuf, sizeof(gJsonPoolBuf));

// RAII lock + rewind for the shared JSON pool. Construct it, build a JsonDocument with .alloc(),
// serialize into a local char buffer, then let it fall out of scope to release. Before the mutex
// exists (only possible ahead of acabBleBegin, when no notify path runs) it degrades to no lock.
struct JsonPoolLock {
    bool locked = false;
    JsonPoolLock() {
        if (gJsonMux && xSemaphoreTake(gJsonMux, portMAX_DELAY) == pdTRUE) locked = true;
        gJsonPool.reset();
    }
    ~JsonPoolLock() { if (locked) xSemaphoreGive(gJsonMux); }
    ArduinoJson::Allocator* alloc() { return &gJsonPool; }
};

// Serializes every characteristic setValue()+notify() PAIR (det/stat/ota) across the tasks that
// emit them: the scanner sink task (live detection), loop() core1 + CfgCb::onWrite core0 (status),
// the OTA host task (ota progress), and loop()'s drain tick (history). Without it two tasks can
// realloc/memcpy the same NimBLEAttValue at once -> torn notify or heap UAF. Created in acabBleBegin
// the same way gJsonMux is. CRITICAL: this lock is taken ONLY around a setValue+notify pair, and
// ONLY after any JsonPoolLock has already been released, so the two mutexes are never held at once
// (no lock-order inversion, no deadlock). notify() does not re-enter these paths, so holding across
// it is safe.
static SemaphoreHandle_t gNotifyMux = nullptr;
struct NotifyLock {
    bool locked = false;
    NotifyLock() { if (gNotifyMux && xSemaphoreTake(gNotifyMux, portMAX_DELAY) == pdTRUE) locked = true; }
    ~NotifyLock() { if (locked) xSemaphoreGive(gNotifyMux); }
};

// nRF app-version hook: real on the dual-radio board (last "V<n>" heard), -1 everywhere else.
__attribute__((weak)) int acabNrfVersion() { return -1; }

// "nRF is mid BLE DFU" hook: real on the dual-radio board (true for a window after a DFU trigger),
// false everywhere else. Lets the status doc emit "nrfup" so the app mutes the co-proc fault banner
// (the nRF legitimately goes silent while it reboots into its bootloader).
__attribute__((weak)) bool acabNrfDfuActive() { return false; }

// Link-owned host-task requests are stamped, checked, and EXECUTED through one lease. A plain token
// check followed by `return true` still had a check->action gap: A could disconnect and B could
// authenticate before loop() actually triggered DFU/power-off. Both link boundaries take this same
// mutex, so an authorized A action either begins entirely before the boundary or is rejected after.
static AcabLinkActionLease gLinkActions;

static bool nrfDfuMayArmNow();
static bool nrfDfuStillAuthorized(void*) { return nrfDfuMayArmNow(); }

bool acabBleRunNrfDfuRequest(AcabBleDeferredLinkAction action, void* context) {
    const AcabLinkActionResult result = gLinkActions.run(
        AcabLinkActionSlot::nrfDfu, nrfDfuStillAuthorized, action, context);
    if (result == AcabLinkActionResult::rejected) {
        Serial.println("[nrf] DFU request expired or link is not secure; power-cycle and retry");
    }
    return result == AcabLinkActionResult::executed;
}

bool acabBleRunPowerOffRequest(AcabBleDeferredLinkAction action, void* context) {
    return gLinkActions.run(AcabLinkActionSlot::powerOff, nullptr, action, context) ==
           AcabLinkActionResult::executed;
}

static void advanceLinkSessionToken() {
    if (!gLinkActions.advance()) {
        // Static allocation should make this unreachable in production. Continue the connection
        // boundary, but every deferred action remains invalid/fail-closed until a later successful
        // boundary; never weaken session isolation because an auxiliary mutex is unavailable.
        Serial.println("[ACAB] deferred link-action lease unavailable; commands disabled");
    }
}
// Tell a connected app the board is deep-sleeping ON PURPOSE (a button-hold or app power-off), so it
// flags the coming link drop as a clean shutdown instead of an error / reconnect spin. Sent by
// powerOffDeepSleep only when it is really about to drop, so the app arms its intent on this and not
// on the mere request - a board that never reaches here never sends it. otaNotify is a no-op with no
// subscriber, and is safe from the loop task (same path acabBleUpdateStatus already notifies from).
static void otaNotify(const char* json);   // defined further down (needs the OTA char handle); fwd-declared for this early caller
void acabBleNotifyPoweringOff() { otaNotify("{\"pwr\":\"off\"}"); }

// The buzzer (alerts) is OUI-Spy hardware; the Mesh-Detect board has none. These
// weak no-ops let this shared service link on a buzzer-less build - oui-spy's
// alerts.cpp provides the strong overrides; mesh-detect falls through to these.
__attribute__((weak)) void    alertsSetBuzzerEnabled(bool) {}
__attribute__((weak)) bool    alertsBuzzerEnabled()         { return false; }
__attribute__((weak)) void    alertsSetVolume(uint8_t)      {}
__attribute__((weak)) uint8_t alertsVolume()                { return 0; }
__attribute__((weak)) void    alertsBeepTest()              {}
// LED master switch: oui-spy/beacon-board override in alerts.cpp, mesh-detect in its main.cpp.
// A build with neither reports the default (on) and ignores the toggle harmlessly.
__attribute__((weak)) void    alertsSetLedEnabled(bool)     {}
__attribute__((weak)) bool    alertsLedEnabled()            { return true; }

// Latest phone GPS the app pushed over the config characteristic. Age is stamped in ESP-IDF's
// 64-bit monotonic microsecond domain, NOT uint32 millis(): a board can remain on external power
// past the 49.7-day millis wrap, and an old owner location must never become "fresh" again then.
static double   gPhoneLat = 0, gPhoneLon = 0;
static uint64_t gPhoneGpsUs = 0;
static bool     gPhoneGpsValid = false;
// The SAME fix, conditionally retained across disconnect ONLY when that session supplied the key
// accepted for the current log generation, and readable only through acabBleGetLastPhoneGps. A
// no-key/mismatched session clears it; every authentication also begins empty. The live triple
// above is always zeroed in onDisconnect. That zeroing otherwise left the
// offline buffer with nothing to stamp: detLogAppend refuses to write while the app is connected,
// so EVERY buffered record is taken during exactly the window in which the live fix has just been
// erased, and landed with lat = lon = 0. This shadow is what the buffer stamps from.
// It is a SEPARATE variable rather than "stop zeroing the live one" on purpose: the live triple
// is what acabBleGetPhoneGps returns, and mesh-detect's transmission boundary calls that. Keeping
// the two apart is what proves the mesh path's behaviour is unchanged.
static double   gLastPhoneLat = 0, gLastPhoneLon = 0;
static uint64_t gLastPhoneGpsUs = 0;
static bool     gLastPhoneGpsValid = false;
// The doubles and uint64 timestamps are not atomic on the 32-bit Xtensa core and they
// cross tasks (BLE host writes them, the scanner task reads them), so a snapshot can tear
// (new high word + old low word). Guard the pair with a short spinlock.
static portMUX_TYPE      gGpsMux = portMUX_INITIALIZER_UNLOCKED;

static void clearPhoneGpsShadow(bool includeRetained) {
    portENTER_CRITICAL(&gGpsMux);
    gPhoneLat = 0; gPhoneLon = 0; gPhoneGpsUs = 0; gPhoneGpsValid = false;
    if (includeRetained) {
        gLastPhoneLat = 0; gLastPhoneLon = 0;
        gLastPhoneGpsUs = 0; gLastPhoneGpsValid = false;
    }
    portEXIT_CRITICAL(&gGpsMux);
}

// Build label for the status "fw" string (oui-spy vs mesh-detect). Set in acabBleBegin.
static const char* gFwLabel = "ACAB-ouispy";
static int gBatteryPct = -1;   // battery %; stays -1 until a sense-divider board reports it
// Live-notify MTU accounting. gNotifyElided counts records that FIT after giving up optional RID
// enrichment (the alert still went out, just shorter); gNotifyOverCap counts the residual case
// where even the minimal record does not fit, which IS a lost live sighting. Both are surfaced in
// the {"diag":true} reply. Atomic because the notify runs off the sink task.
// Pairing-window deadline in millis(). 0 = never opened, i.e. closed. RAM ONLY, deliberately: a
// power cycle is the documented way to reopen it, so persisting it would defeat the whole design.
static volatile uint32_t gPairWindowUntil = 0;
static volatile bool     gPairWindowArmed = false;
// One-way latch. See pair_window.h: the signed millis() comparison flips sign after ~24.8 days of
// uptime and would report the window OPEN again. Once closed, stays closed until a power cycle,
// which is already the only documented way to reopen it.
static volatile bool     gPairWindowLatchedClosed = false;
// Does THIS TARGET enforce the pairing window at all? False until the target opts in, via EITHER
// of two entry points:
//
//   acabBlePairGateEnable()    - enforcement ONLY. beacon-board calls this UNCONDITIONALLY, so a
//                                warm boot enforces the gate without opening any window.
//   acabBleOpenPairingWindow() - opens a window AND enables, for a genuine physical start.
//
// "unless the target armed the window at least once" was the old test, and it is no longer true:
// enforcement and "a person just turned this on" were deliberately split into separate questions
// and separate calls, precisely so a warm continuation can enforce without arming. Before that
// split, every OTA restart, panic, watchdog and brownout came back with the gate OFF and admitted
// any phone indefinitely.
//
// This flag exists because the gate lives in shared code. Without it, a target that never calls
// acabBleOpenPairingWindow() (mesh-detect) inherits the REJECTION with no way to ever open a
// window, i.e. no phone could pair to it again, ever. That is strictly worse than not having the
// feature. Enforcement is therefore opt-in, and a target that does not opt in behaves exactly as it
// did before this feature existed. Deliberately NOT a compile-time flag: the arming call site is
// the honest declaration of intent, and one mechanism beats two.
static volatile bool     gPairGateEnabled = false;
// Has advertising been INTENTIONALLY started? False between acabBleBegin() and
// acabBleStartAdvertising() on targets that defer. The advertising supervisor in the tick below
// must respect this: it exists to restart an advertisement that stopped unexpectedly, and without
// the flag it would helpfully start the one we are deliberately holding back.
static volatile bool     gAdvIntended = false;

static std::atomic<uint32_t> gNotifyElided{0};
static std::atomic<uint32_t> gNotifyOverCap{0};
// The same accounting for the offline-buffer REPLAY, which the live counters above never covered.
// Before peek/commit, an oversized replayed record simply vanished uncounted. They ship in the {"diag":true}
// reply as hTrim/hOver, and docs/ble-protocol.md carries a row for each beside nOver in its
// drop-counter table. Keep those rows in step with these names if either one moves.
// gDrainTrimmed counts replayed records that fit only after the HIST_TRIM ladder gave something
// up; gDrainOverCap counts the ones that still did not fit. The drain now peeks and commits only
// after notify, so an over-cap row BLOCKS that attempt and remains replayable instead of destroying
// evidence. The standard iPhone path should never increment it: the final bounded-core rung is
// statically budgeted below 182 B.
// Written on the loop task (acabBleDrainTick), read on the NimBLE host task by the diag reply,
// hence atomic.
static std::atomic<uint32_t> gDrainTrimmed{0};
static std::atomic<uint32_t> gDrainOverCap{0};
static bool gCharging = false; // battery charging (dual-radio "chg"); set by acabBleSetCharging

static NimBLEServer*         gServer = nullptr;
static NimBLECharacteristic* gDetChar = nullptr;
static NimBLECharacteristic* gCfgChar = nullptr;
static NimBLECharacteristic* gStatChar = nullptr;
static NimBLECharacteristic* gOtaChar = nullptr;
// A physical GAP link is not yet a trusted app session. Keep the two states separate so a peer
// that stalls before encrypted bonding cannot suppress offline logging, receive notifications, or
// make the UI report a connection. gLinkConnected only prevents advertising from being restarted
// underneath the controller while SMP is in flight.
static volatile bool         gLinkConnected = false;
static volatile bool         gConnected = false;       // encrypted and bonded, or known bonded
// Per-link gate established before encrypted config traffic can reach CfgCb. In disabled-buffer
// mode it means the boot-lifetime coredump erase token is already durable.
static volatile bool         gConfigPrivacyReady = false;
static volatile bool         gSessionReplayKeySupplied = false;
// Authentication has crossed the owner boundary but gConnected is not publishable until GPS is
// cleared and the durable config-session privacy token lands. acabBleClientConnected includes this
// temporary gate, so scanner/GPS users never mistake that window for an away session.
static volatile bool         gOwnerCaptureBlocked = false;
// Session-local key handshake state. A mismatch is surfaced in Status only for this authenticated
// link; explicit clear is the sole authority to replace a nonempty generation with another key.
static volatile bool         gSessionKeyMismatch = false;
static volatile bool         gSessionKeyReplacementApproved = false;
static volatile uint16_t     gConnHandle = 0xffff;
static volatile uint32_t     gAuthStartedMs = 0;
static volatile bool         gPeerKnownAtConnect = false;
static volatile bool         gBoardHadBondAtConnect = false;
static const uint32_t        AUTH_TIMEOUT_MS = 30000;

static bool nrfDfuMayArmNow() {
    return acabLegacyDfuMayArm(gConnected, acabBlePairWindowOpen());
}

// NimBLE host-privacy re-arm. Private header (ble_hs_pvcy_priv.h), no NimBLE-Arduino wrapper.
extern "C" int ble_hs_pvcy_rpa_config(uint8_t enable);
#define ACAB_NIMBLE_ENABLE_RPA 1

// RAW GAP TAP. Observer only, returns 0, the normal handlers still run.
//
// WHY THIS EXISTS: NimBLE-Arduino's C++ callbacks DROP the fields that carry the reason.
// onAuthenticationComplete gets only the conn_desc and discards event->enc_change.status, and the
// no-desc onDisconnect discards event->disconnect.reason. So from the board side "the bond
// resolved", "the phone had no bond record", "the board had no bond record" and "the link timed
// out" all look identical: a connect followed by a drop. That ambiguity is what turned this into
// four rounds of hypothesis. setCustomGapHandler registers through ble_gap_event_listener_register,
// which is the same dispatch the wrapper sits on, so it sees the RAW event with .status intact.
//
// It also catches REPEAT_PAIRING, which is the trap: NimBLE-Arduino's stock handler DELETES the
// existing bond ("sacrifices security for convenience", NimBLEServer.cpp) and re-pairs. That path
// reports encrypted=1 bonded=1, so it reads as a SUCCESS in every other log line here while
// actually being a bond loss, and it lets any stranger evict the owner's bond.
static int acabGapTap(ble_gap_event* ev, void*) {
    switch (ev->type) {
    case BLE_GAP_EVENT_ENC_CHANGE:
        Serial.printf("[ACAB] enc_change status=%d (0=ok, 5=ENOENT no bond record, 7=ENOTCONN link gone)\n",
                      ev->enc_change.status);
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        Serial.printf("[ACAB] disconnect reason=%d (0x%02x)\n",
                      ev->disconnect.reason, ev->disconnect.reason & 0xff);
        break;
    case BLE_GAP_EVENT_REPEAT_PAIRING:
        // OBSERVE ONLY, WE CANNOT STOP IT. NimBLE-Arduino's stock handler deletes the existing
        // bond and re-pairs ("sacrifices security for convenience", NimBLEServer.cpp), which is
        // both a silent bond-loss route and a downgrade: any peer that triggers repeat pairing
        // evicts the owner's bond. It cannot be overridden from here, because
        // ble_gap_event_listener_call iterates listeners and returns 0 unconditionally, so this
        // handler's return value is discarded and only NimBLEServer's reply is honoured. Changing
        // it means patching the pinned library, which a clean checkout would silently undo. So the
        // best available move is to make it VISIBLE: without this line a bond deletion looks
        // identical to a successful re-pair in every other log the board emits.
        Serial.println("[ACAB] REPEAT_PAIRING: the stack is about to DELETE the existing bond");
        break;
    default: break;
    }
    return 0;
}

// Re-arm advertising after the stack preempts it. LOAD-BEARING, and the failure it prevents is
// worse than the leak address privacy was added to fix.
//
// ble_hs_pvcy_rpa_config arms an RPA rotation timer (CONFIG_BT_NIMBLE_RPA_TIMEOUT, 900 s by
// default). Each rotation calls ble_gap_preempt(), which STOPS advertising, and ble_gap_preempt_done
// then delivers ADV_COMPLETE with reason BLE_HS_EPREEMPTED and restarts NOTHING. With no completion
// callback that event is dropped on the floor and the board goes silent 15 minutes after boot and
// stays silent until it is power-cycled - which is exactly the product's normal case, a board left
// running in a car with the phone connecting later.
//
// Restarting from inside the callback is legal: preempt_done clears the preempted flag inside the
// lock BEFORE dispatching, so start() here does not return BLE_HS_EPREEMPTED.
static void advCompleteCb(NimBLEAdvertising* a) {
    if (!gLinkConnected && a) a->start(0, advCompleteCb);
}
// The record layer's drainGeneration prevents a stale peek from advancing a replacement drain,
// but the BLE envelope has its OWN cross-task state: begin, end, and the number accepted by the
// host queue. CfgCb/onDisconnect run on NimBLE's host task while acabBleDrainTick runs on loop(),
// so three loose globals here let a new {sync} land between queue/commit/count: the old callback
// then incremented the NEW drain's count, and the remainder of the burst sent new-generation rows
// before its begin sentinel.
//
// The replay mutex makes a transport generation a real transaction. The final generation check,
// queueDetNotify, detLogCommitDrain, and the matching state update occur while it is held; a new
// sync/disconnect therefore happens wholly before or wholly after that boundary. JSON construction
// and flash peek remain outside the lock. Lock order is Replay -> Notify -> NimBLE (the queue path);
// no code may acquire Replay while holding Notify.
static SemaphoreHandle_t     gReplayMux = nullptr;
static AcabReplaySession     gReplaySession;
struct ReplayLock {
    bool locked = false;
    ReplayLock() {
        if (gReplayMux && xSemaphoreTake(gReplayMux, portMAX_DELAY) == pdTRUE) locked = true;
    }
    ~ReplayLock() { if (locked) xSemaphoreGive(gReplayMux); }
};

static void invalidateReplayLocked() {
    gReplaySession.invalidate();
    detLogStopDrain();
}

static void stopReplaySession() {
    ReplayLock rl;
    if (!rl.locked) { detLogStopDrain(); return; } // pre-init only; fail closed at the record layer
    invalidateReplayLocked();
}

static void startReplaySession(uint32_t lastSeq, uint32_t clientLogGeneration) {
    ReplayLock rl;
    if (!rl.locked) { detLogStopDrain(); return; } // never stream without a protected envelope
    const DetLogDrainStartResult result = detLogStartDrain(lastSeq, clientLogGeneration);
    if (result == DET_LOG_DRAIN_REJECTED) {
        // A keyless/unavailable record layer did not accept the sync. Do not leave a transport
        // session active forever waiting for a begin that can never be produced.
        gReplaySession.invalidate();
    } else {
        // STARTED, EMPTY, and PENDING are all accepted sessions. EMPTY still emits a truthful
        // begin(n=0)/end(n=0); PENDING waits for the loop-side NVS/startup retry.
        gReplaySession.start();
    }
}

// Destructive/key-lifecycle config writes can invalidate det_log's generation just as surely as a
// new {sync}. Run them under the transport mutex too, and invalidate BEFORE touching the record
// layer, so a burst cannot queue an old-key/cleared row in the gap. A key push always aborts an
// existing envelope: the documented handshake immediately follows it with epoch + sync, while a
// surprise key write mid-drain is safer as an explicit retry than as a mixed-key envelope.
static DetLogKeyResult installReplayKey(const uint8_t key[32],
                                        bool allowDestructiveReplacement) {
    ReplayLock rl;
    if (!rl.locked) {
        detLogStopDrain();
        return DET_LOG_KEY_REJECTED;
    }
    invalidateReplayLocked();
    return detLogSetKey(key, allowDestructiveReplacement);
}

static void clearReplayLog() {
    ReplayLock rl;
    if (!rl.locked) { detLogStopDrain(); detLogClear(); return; }
    invalidateReplayLocked();
    detLogClear();
}

static void disableReplayLog() {
    ReplayLock rl;
    if (!rl.locked) { detLogStopDrain(); detLogSetEnabled(false); return; }
    // Stop while the decrypting key still exists. detLogSetEnabled(false) deliberately zeros it
    // but retains the encrypted rows for a later same-key replay.
    invalidateReplayLocked();
    detLogSetEnabled(false);
}
// Replay back-pressure. NimBLECharacteristic::notify() is void in the pinned NimBLE 1.4.x, so
// the replay path uses the underlying ble_gatts_notify_custom() result (see queueDetNotify) and
// commits its flash cursor only when the host accepted the mbuf. We still pace by the shared mbuf
// pool: blasting into a full pool creates needless rejects and can starve live notification
// traffic. A notification remains unacknowledged on air; seq + begin/end still detect that class.
extern "C" int os_msys_num_free(void);
static const int             DRAIN_MBUF_MIN = 6;   // hold this many mbufs free for the live path
// Records per loop pass while the pool keeps headroom. One-per-tick pinned the replay to the
// loop rate (~50/s at delay(20): a full ring took 8-10 minutes of screen-on syncing); a bounded
// burst drains it in about a minute, and the per-notify mbuf re-check in the burst loop still
// yields to live traffic the moment the pool tightens.
static const int             DRAIN_BURST_MAX = 8;

// Push an OTA progress/result JSON to the app (the ota_update module calls this).
static void otaNotify(const char* json) {
    if (!gOtaChar) return;
    NotifyLock nl;   // serialize the setValue+notify pair against the other characteristic writers
    gOtaChar->setValue((uint8_t*)json, strlen(json));
    if (gConnected) gOtaChar->notify();
}

// While an OTA is streaming, quiet the radios so flash writes don't fight the scan load, then
// put them back the way the user had them.
//
// RESTORE, never force-on: only the success path reboots (otaFinish OK). Six failure paths
// resume in place - disconnect mid-update, a write/begin/finish error, an explicit abort, the
// stall watchdog - and an unconditional resume silently switches radios ON for a user who had
// turned them off. gOtaPaused also makes the resume a no-op when nothing was paused, so a
// stray un-quiesce can't do it either.
//
// The BLE half goes through acabScannerSetBLE rather than poking "S0"/"S1" directly, so
// gBleEnabled and the co-processor command cannot diverge: on the beacon board cfg.enableBLE
// is false, gScan is never created, and that command is the ONLY BLE gate, so a raw send
// restarts the nRF scan while the status the app reads still says BLE is off. Disabling the
// BLE *scan* does not touch the GATT link the update itself rides on.
//
// Returns whether this call actually changed the pause state, and the begin path must honour
// that. A duplicate "begin" arriving while an update is already streaming quiesces nothing (the
// saved state belongs to the live update and must not be clobbered), otaBegin then answers
// OTA_ERR_BUSY, and un-quiescing from that error branch would switch the LIVE update's radios
// back on. Only un-quiesce from an error path that did the quiescing itself.
//
// CALLED FROM TWO TASKS, WHICH IS WHY IT LOCKS. The NimBLE host task reaches it through
// OtaCb::onWrite, handleOtaControl's begin/end/abort and ServerCb::onDisconnect; the loop task
// reaches it through acabBleOtaWatchdog (both the stall abort and the expired deferred finish).
// The three statics below are a single transaction - read gOtaPaused, snapshot the radio state,
// set the flag, drive the radios - and interleaving two of those across tasks can save the
// QUIESCED state as the user's state. The board then finishes the update, restores WiFi and BLE
// scanning to OFF, and goes on advertising, connecting and reporting itself healthy while
// detecting nothing. The window is sub-millisecond and needs a hand-timed retry to hit (both
// apps give up at 20 s, the board watchdog fires at 30 s), and the damage is RAM-only, reported
// truthfully in the status frame and cleared by a reboot - but the fix is one mutex, and this
// file already keeps gJsonMux and gNotifyMux for exactly this class of problem.
//
// Held across acabScannerSetWiFi/SetBLE deliberately: those calls ARE the transition, and
// nothing they touch takes this mutex, so there is no inversion. The host task can now wait on
// a radio transition the loop task started, which it already did that work for itself anyway.
static bool gOtaPaused    = false;
static bool gOtaSavedBle  = true;
static bool gOtaSavedWifi = true;
static SemaphoreHandle_t gOtaQuiesceMux = nullptr;   // created in acabBleBegin, like the others

static bool otaQuiesce(bool pause) {
    // Before the mutex exists no OTA path can run (every caller is a BLE callback or the loop
    // watchdog, all of them post-acabBleBegin), so degrade to no lock rather than refuse.
    const bool locked = gOtaQuiesceMux &&
                        xSemaphoreTake(gOtaQuiesceMux, portMAX_DELAY) == pdTRUE;
    bool changed = true;
    if (pause) {
        if (gOtaPaused) changed = false;             // already quiesced: don't clobber the saved state
        else {
            gOtaSavedBle  = acabScannerBLEEnabled();
            gOtaSavedWifi = acabScannerWiFiEnabled();
            gOtaPaused    = true;
            acabScannerSetWiFi(false);
            acabScannerSetBLE(false);                // also stops the nRF's scan ("S0") on the dual board
        }
    } else {
        if (!gOtaPaused) changed = false;            // nothing to restore
        else {
            gOtaPaused = false;
            acabScannerSetWiFi(gOtaSavedWifi);
            acabScannerSetBLE(gOtaSavedBle);
        }
    }
    if (locked) xSemaphoreGive(gOtaQuiesceMux);
    return changed;
}

// Cap on the JSON we put in one notify. Raised past the old 244 (247-MTU) limit because the
// status frame grew (every detector toggle + the diagnostics) past it: we ASK for a 512 MTU
// (setMTU below, and Android's requestMtu(512); iOS never asks and lands near 185) and cap at
// 500, which fits the STATUS_JSON_MAX scratch buffers and the 509-byte wire limit of MTU 512
// (and the 512-byte attribute cap) with margin, carrying the status and a fully-populated
// drone/history record. NOTIFY_MAX is only the CEILING - what a given peer can actually receive
// is notifyCap() below, which is usually the smaller number.
static const size_t          NOTIFY_MAX = 500;

// Length budget for the STATUS-characteristic builders, and the size gStatChar's value buffer is
// warmed to in acabBleBegin. The memory-safety invariant binds this constant to
// acabBleUpdateStatus specifically, because that is the ONLY builder that setValues: once the
// NimBLEAttValue capacity has been ratcheted to STATUS_JSON_MAX, no later setValue can grow it and
// no realloc can race an ATT READ. Warming to NOTIFY_MAX was NOT enough - only the notify() is
// size-gated, and that setValue was unconditional at the time - so a 501..512 byte status frame
// reallocated the buffer a peer might be reading.
//
// THE SCRATCH IS DECLARED ONE BYTE LARGER, AND len >= STATUS_JSON_MAX MEANS OVERFLOW. That extra
// byte exists only so truncation is DETECTABLE: ArduinoJson's StaticStringWriter stops at the end
// of the buffer it is given and returns what it wrote, appending the NUL only when the document
// was shorter, so serializeJson returning exactly the buffer size is indistinguishable from an
// exact fit. Sizing the scratch AT the cap therefore let a >= 512-byte document be stored as JSON
// cut mid-token, which both apps drop unparsed - and because 512 is already past notifyCap()'s
// NOTIFY_MAX ceiling, the corrupt READ value was the only delivery path left, so the status simply
// froze. Rejecting a document that reaches the cap (rather than only one that passes it) costs at
// most a single legal 512-byte frame and buys one predicate that firmware, the warm capacity and
// the host-test budget all state the same way: a published status is < STATUS_JSON_MAX and whole.
//
// acabBleSendDiag borrows the same constant because it shares the characteristic and the shared
// JSON pool. IT IS NOT THE DEFECT, AND ITS COPY OF THE GUARD IS A BACKSTOP RATHER THAN A LIVE
// PATH: it is NOTIFY-ONLY (see the banner on it), never touches the stored value, and its notify
// is already gated at notifyCap() <= NOTIFY_MAX, so it could not publish a truncated frame in the
// first place - and its widest possible document, every counter at its uint32 maximum plus a full
// core-dump block with a 40-char ELF SHA, comes to about 350 B. It carries the guard anyway for
// two reasons: the two builders share this constant and should not end up with two different
// truncation contracts, and if a setValue is ever added to that path the trap is already shut.
// 512 is BLE_ATT_ATTR_MAX_LEN, the largest an ATT attribute may be, so this cannot be raised.
static const size_t          STATUS_JSON_MAX = 512;
static_assert(STATUS_JSON_MAX <= BLE_ATT_ATTR_MAX_LEN,
              "STATUS_JSON_MAX exceeds the ATT attribute cap; setValue would refuse the frame");

// Rate-limited (5 s, same gate as the other status-path warnings) console line for a document that
// did not fit its builder. Overflow is a STICKY condition - the counters that push the status over
// only grow - so an ungated line would print on every build for the rest of the session.
static void statusJsonOverflowWarn(const char* which) {
    static uint32_t sLastOverflowWarn = 0;
    if (millis() - sLastOverflowWarn > 5000) {
        sLastOverflowWarn = millis();
        Serial.printf("[ACAB] %s JSON overflowed the %u B builder - frame DROPPED, last good "
                      "value left in place\n", which, (unsigned)STATUS_JSON_MAX);
    }
}

// Live negotiated ATT MTU with the connected peer. Starts at the BLE default 23 and is updated
// on the MTU-exchange callback (ServerCb::onMTUChange); reset to 23 on each new connect. Every
// notify path caps its frame at notifyCap() below, so a peer that negotiates a small MTU (e.g.
// iPhone 185) gets frames sized to what it can actually receive instead of a silently dropped
// notify. A small MTU never costs the READ path its freshness: acabBleUpdateStatus stores every
// COMPLETE frame before it consults notifyCap(). Only an OVERFLOWING frame skips the store, and
// that is a size fault, not an MTU one - see STATUS_JSON_MAX.
static volatile uint16_t     gPeerMtu = 23;

// Per-notify size cap: the smaller of NOTIFY_MAX and the peer's usable payload (MTU - 3 bytes of
// ATT notify header). gPeerMtu is always >= 23 so (gPeerMtu - 3) >= 20.
static size_t notifyCap() {
    size_t mtuCap = (gPeerMtu > 3) ? (size_t)(gPeerMtu - 3) : 0;
    return (mtuCap < NOTIFY_MAX) ? mtuCap : NOTIFY_MAX;
}

// Queue one Detection-characteristic notification and report whether the NimBLE HOST accepted
// ownership of its mbuf. NimBLECharacteristic::notify() discards this return code, which is not
// sufficient for replay: advancing the durable cursor after BLE_HS_ENOMEM would irretrievably
// skip evidence. There is only one server connection; getSubscribedCount() guards the CCCD state
// that the raw host call does not inspect for us. Notify remains unacknowledged by the peer, so
// the app's sequence-gap/resync contract is still required after a successful queue operation.
static bool queueDetNotify(const uint8_t* value, size_t len) {
    NotifyLock nl;
    if (!nl.locked || !gDetChar || !gConnected || gConnHandle == 0xffff ||
        gDetChar->getSubscribedCount() == 0 || len == 0 || len > UINT16_MAX) return false;
    gDetChar->setValue(value, len);   // preserve the characteristic's existing READ value contract
    struct os_mbuf* om = ble_hs_mbuf_from_flat(value, (uint16_t)len);
    if (!om) return false;
    // ble_gatts_notify_custom owns/frees `om` on both success and error.
    return ble_gatts_notify_custom(gConnHandle, gDetChar->getHandle(), om) == 0;
}

// Chunked ignore/watch staging. The app may split a long list across several config writes:
// a non-final chunk carries {"more":true} and is appended here WITHOUT committing; the final
// chunk (no "more", or "more":false) appends then commits the whole staged list to the scanner.
// A single small write with no "more" stages then immediately commits, i.e. behaves as before.
// Config writes are serialized on the BLE host task, so plain file-scope state is safe here.
// Reset on every connect/disconnect (see ServerCb) so an interrupted chunk sequence can't leak
// stale MACs into the next connection's committed list. NOTE: a chunked write carries at most ONE
// of ignore/watch (the apps split only one list per write), so the single "more" flag is unambiguous.
static uint8_t  gIgnoreStage[256][6];
static int      gIgnoreStageN = 0;
static uint8_t  gWatchStage[256][6];
static int      gWatchStageN  = 0;
// Has this PEER committed a NON-EMPTY list for that key on THIS connection? See the empty-commit
// rule below. Reset with the stage counters on every connect/disconnect, which is what makes it
// per-peer: a second phone starts the connection having proved nothing.
static bool     gIgnoreHadContent = false;
static bool     gWatchHadContent  = false;

// ---- server connection lifecycle ----
class ServerCb : public NimBLEServerCallbacks {
    void onConnect(NimBLEServer* srv, ble_gap_conn_desc* d) override {
        // Host-task requests belong to one physical link. Never let a command queued by phone A
        // survive long enough for loop() to consume it while phone B owns the connection.
        advanceLinkSessionToken();
        gConfigPrivacyReady = false;
        gSessionReplayKeySupplied = false;
        // Do not clear gOwnerCaptureBlocked here. A healthy disconnect released it atomically with
        // the away generation; if that publication failed, its true value is a deliberate
        // fail-closed latch which only a later successful auth/disconnect boundary may release.
        gSessionKeyMismatch = false;
        gSessionKeyReplacementApproved = false;
        // desc overload: peer_id_addr is the RESOLVED identity when the bond resolved, and still
        // the rotating RPA when it did not. That one field separates the two cases at connect
        // time, before security has had a chance to fail.
        if (d) Serial.printf("[ACAB] peer_id type=%d %02x:%02x:%02x:%02x:%02x:%02x\n",
                             d->peer_id_addr.type, d->peer_id_addr.val[5], d->peer_id_addr.val[4],
                             d->peer_id_addr.val[3], d->peer_id_addr.val[2],
                             d->peer_id_addr.val[1], d->peer_id_addr.val[0]);
        // ---- PAIRING WINDOW GATE -------------------------------------------------------------
        // A peer we have never bonded with may only proceed while the post-power-on window is open.
        // Rejecting HERE is the point of the whole design: this runs before any SMP traffic, so the
        // stranger never reaches the pairing exchange that NimBLE-Arduino 1.4.3 can service by
        // DELETING the legitimate owner's bond. Refusing later, at authentication-complete, would
        // be too late to protect it. See ACAB_PAIR_WINDOW_MS in the header.
        //
        // Both addresses are checked because a bonded phone can present either: peer_id_addr is the
        // resolved identity once the controller matched its IRK, peer_ota_addr is what is on air
        // (still the rotating RPA when resolution has not happened). Treating "known" as the OR of
        // the two is what lets an existing iPhone reconnect outside the window.
        bool known = false;
        const bool boardHadBond = acabBleBondCount() > 0;
        if (d) {
            known = NimBLEDevice::isBonded(NimBLEAddress(d->peer_id_addr)) ||
                    NimBLEDevice::isBonded(NimBLEAddress(d->peer_ota_addr));
            // See acabPairAdmit for what each input means and why. Short version: the only peer
            // ever refused is a stranger, outside the window, on a board that ALREADY has an owner.
            // A board with no bonds pairs freely, so an out-of-box unit never makes the customer
            // learn the recovery step on their very first connect.
            if (!acabPairAdmit(gPairGateEnabled, boardHadBond, known,
                               acabBlePairWindowOpen())) {
                Serial.println("[pair] window CLOSED and peer is not bonded -> rejecting. "
                               "Power-cycle the board to open a fresh 2-minute window.");
                // Disconnect, and do NOT touch the bond store: the existing owner's bond is
                // untouched by this path, which is the property the whole gate exists to preserve.
                if (srv) srv->disconnect(d->conn_handle);
                return;
            }
        }
        gLinkConnected = true;
        gConnected = false;
        gConnHandle = d ? d->conn_handle : 0xffff;
        gAuthStartedMs = millis();
        gPeerKnownAtConnect = known;
        gBoardHadBondAtConnect = boardHadBond;
        gPeerMtu = 23;   // reset to the BLE default; the MTU exchange bumps it right after connect
        gIgnoreStageN = 0; gWatchStageN = 0;   // fresh connection: drop any half-staged chunk sequence
        gIgnoreHadContent = false; gWatchHadContent = false;   // and this peer has proved nothing yet
        // Connection lifecycle on the wire. Added because the board previously said nothing when a
        // phone attached or left, which made "did the bond survive the update" impossible to answer
        // from the board side: a working reconnect and a silent failure looked identical here.
        Serial.println("[ACAB] BLE link connected; waiting for encrypted bond");
    }
    // Pairing outcome, which is the ONLY way to tell "the bond resolved" from "the link came up and
    // then security failed". Added 2026-08-02 after a bonded phone connected, chirped, and dropped:
    // from the board side those two look identical without this.
    void onAuthenticationComplete(ble_gap_conn_desc* desc) override {
        if (!desc) {
            Serial.println("[ACAB] pairing failed: no connection descriptor");
            if (gServer && gConnHandle != 0xffff) gServer->disconnect(gConnHandle);
            return;
        }
        Serial.printf("[ACAB] pairing: encrypted=%d authenticated=%d bonded=%d peer_id_type=%d "
                      "peer_id=%02x:%02x:%02x:%02x:%02x:%02x\n",
                      desc->sec_state.encrypted, desc->sec_state.authenticated,
                      desc->sec_state.bonded, desc->peer_id_addr.type,
                      desc->peer_id_addr.val[5], desc->peer_id_addr.val[4],
                      desc->peer_id_addr.val[3], desc->peer_id_addr.val[2],
                      desc->peer_id_addr.val[1], desc->peer_id_addr.val[0]);
        // No-I/O Just Works pairing does not provide MITM authentication, so `authenticated` is
        // expected to be false. The security boundary this product can enforce is encryption plus
        // a persistent bond. A previously known bonded peer is accepted on an encrypted reconnect.
        const bool secure = desc->sec_state.encrypted &&
                            (desc->sec_state.bonded || gPeerKnownAtConnect);
        const bool stillAdmitted = acabPairAdmit(gPairGateEnabled,
                                                  gBoardHadBondAtConnect,
                                                  gPeerKnownAtConnect,
                                                  acabBlePairWindowOpen());
        if (!secure || !stillAdmitted) {
            Serial.println(!secure
                ? "[ACAB] pairing failed to establish an encrypted bond; disconnecting"
                : "[ACAB] pairing window closed before stranger authenticated; disconnecting");
            if (gServer && gConnHandle != 0xffff) gServer->disconnect(gConnHandle);
            return;
        }
        // Close offline append admission BEFORE clearing prior-session GPS or entering the NVS
        // pre-arm. gConnected intentionally remains false until that work succeeds, so without this
        // separate owner boundary a queued A-era SinkItem could land during B's authentication.
        // Raise the service-side view first: it makes acabBleClientConnected true in the tiny window
        // before det_log advances its mutex-owned epoch. The block is cleared only after
        // gConnected=true, or by disconnect after another epoch publication, so there is no gap.
        gOwnerCaptureBlocked = true;
        if (!acabScannerBlockCaptureForOwnerSession()) {
            Serial.println("[ACAB] config session denied: capture admission boundary unavailable");
            if (gServer && gConnHandle != 0xffff) gServer->disconnect(gConnHandle);
            return;
        }
        // A retained fix belongs to the session that supplied it, not merely to "some bonded
        // peer". Boards can hold multiple bonds, so an already-known phone B is just as capable of
        // following phone A as a newly paired phone. Start EVERY authenticated session location-
        // empty before config admission; this phone can immediately repopulate its own fix. The
        // retained shadow still serves its purpose between disconnect and the next authentication.
        clearPhoneGpsShadow(true);
        // Only an authenticated owner may cause the destructive privacy token/boot hold. NimBLE
        // serializes these host callbacks, and CfgCb checks this flag before getValue(), so queued
        // writes remain inert until the synchronous durable pre-arm succeeds.
        gConfigPrivacyReady = detLogPrepareConfigSession();
        if (!gConfigPrivacyReady) {
            Serial.println("[ACAB] config session denied: privacy erase token unavailable");
            if (gServer && gConnHandle != 0xffff) gServer->disconnect(gConnHandle);
            return;
        }
        gConnected = true;
        if (!acabScannerAdmitCaptureForOwnerSession()) {
            // Keep both public connection views blocked while rejecting. Scanner claims remain at
            // the zero sentinel until onDisconnect publishes a fresh away-session epoch.
            gConnected = false;
            Serial.println("[ACAB] config session denied: capture admission publish failed");
            if (gServer && gConnHandle != 0xffff) gServer->disconnect(gConnHandle);
            return;
        }
        gOwnerCaptureBlocked = false;
        // The Status characteristic retains its prior value across links. Rebuild it now so a new
        // owner cannot read the preceding session's transient keymis:true before its first write.
        acabBleUpdateStatus();
        Serial.println("[ACAB] BLE peer secure and ready");
    }
    // Track the negotiated MTU so every notify path can size to what the peer accepts (see
    // notifyCap). Fires after connect once the client exchanges MTU.
    void onMTUChange(uint16_t mtu, ble_gap_conn_desc*) override {
        gPeerMtu = mtu;
        Serial.printf("[ACAB] MTU negotiated: %u\n", (unsigned)mtu);
    }
    void onDisconnect(NimBLEServer*) override {
        const bool retainGpsForAwayRows = gSessionReplayKeySupplied;
        // Invalidate link-owned actions immediately, before the slower scanner/replay cleanup.
        // A delayed loop drain must never execute A's DFU or shutdown request under phone B.
        advanceLinkSessionToken();
        // Disconnect is deliberately two-phase. Reserve a fresh det_log owner epoch and publish
        // the scanner's zero sentinel BEFORE connected=false becomes visible. Any radio item
        // claimed during teardown therefore belongs to the old capture generation and carries no
        // admissible owner token. ReArm below publishes the away epoch and bumps that generation
        // only after GPS/replay/key cleanup, so such an item cannot consume the whole away window.
        // Keep the service-side gate raised too: detLogEndConfigSession may still be scrubbing a
        // disabled-session key, and no away append may enter on that stale key in the meantime.
        gOwnerCaptureBlocked = true;
        if (!acabScannerBlockCaptureForOwnerSession()) {
            Serial.println("[ACAB] disconnect capture reserve unavailable; retrying after teardown");
        }
        gLinkConnected = false;
        gConnected = false;
        gConfigPrivacyReady = false;
        gSessionReplayKeySupplied = false;
        gSessionKeyMismatch = false;
        gSessionKeyReplacementApproved = false;
        gConnHandle = 0xffff;
        gAuthStartedMs = 0;
        gPeerKnownAtConnect = false;
        gBoardHadBondAtConnect = false;
        // The live fix always ends with its authenticated connection. The retained half may feed
        // only encrypted away-window rows, and only if this session proved the key for the current
        // log generation. A mismatched/no-key phone's location must never be stamped onto rows the
        // prior key owner can later decrypt.
        clearPhoneGpsShadow(!retainGpsForAwayRows);
        gIgnoreStageN = 0; gWatchStageN = 0;   // drop any half-staged chunk sequence on link drop
        gIgnoreHadContent = false; gWatchHadContent = false;
        // A link drop mid-update must not leave OTA stuck BUSY with the radios paused:
        // abort the session and un-quiesce so the next connect can start fresh.
        if (otaInProgress()) { otaAbort(); otaQuiesce(false); }
        // Abort any in-flight replay drain. The record cursor and complete BLE transport session
        // are invalidated together under gReplayMux, so a loop-task completion captured on this
        // link cannot mutate (or queue into) the next authenticated link even if its handle is
        // reused. Without this, a reconnect that races ahead of the app's re-arming {sync} could
        // resume streaming hist frames from the stale cursor with NO fresh {"hist":"begin"}
        // lead-in (orphan records outside any begin/end envelope). Force the next drain to wait
        // for a {sync}.
        stopReplaySession();
        // This is intentionally unconditional. detLogEndConfigSession is a no-write no-op while
        // buffering is enabled (and preserves enable-owned staged state), but while disabled it
        // scrubs any replay-only key accepted earlier on this link even if a later mismatched offer
        // revoked gSessionReplayKeySupplied before disconnect.
        detLogEndConfigSession();
        // Complete the reserved disconnect boundary LAST. This atomically publishes a fresh
        // scanner generation with its away-session admission epoch, then clears the service gate
        // under that same scanner lock. Claims made during cleanup remain in the prior generation
        // and are eligible again on their next sighting. A failed completion deliberately leaves
        // both the scanner zero sentinel and service gate in their fail-closed states.
        if (!acabScannerReArmCapture(&gOwnerCaptureBlocked)) {
            Serial.println("[ACAB] disconnect capture completion failed; away capture fail-closed");
        }
        Serial.println("[ACAB] BLE peer disconnected");
        NimBLEDevice::getAdvertising()->start(0, advCompleteCb);   // become discoverable again
    }
};

// Parse "aa:bb:cc:dd:ee:ff" into 6 bytes. Returns false if malformed.
static bool parseMac6(const char* s, uint8_t out[6]) {
    unsigned b[6];
    if (!s || sscanf(s, "%x:%x:%x:%x:%x:%x",
                     &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]) != 6) return false;
    for (int i = 0; i < 6; i++) out[i] = (uint8_t)b[i];
    return true;
}

// Decode n*2 hex chars into n bytes (for the offline-buffer at-rest key). False on bad input.
static int hexNib(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
static bool hexToBytes(const char* hex, uint8_t* out, size_t n) {
    if (!hex || strlen(hex) != n * 2) return false;
    for (size_t i = 0; i < n; i++) {
        int hi = hexNib(hex[i * 2]), lo = hexNib(hex[i * 2 + 1]);
        if (hi < 0 || lo < 0) return false;
        out[i] = (uint8_t)((hi << 4) | lo);
    }
    return true;
}
static void zeroSecret(void* value, size_t n) {
    volatile uint8_t* p = (volatile uint8_t*)value;
    while (n--) *p++ = 0;
}

// ---- OTA image bytes from the app (raw, write-no-response for throughput) ----
class OtaCb : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic* c) override {
        std::string v = c->getValue();
        if (v.empty()) return;
        OtaResult r = otaWrite((const uint8_t*)v.data(), v.size());
        if (r != OTA_OK) {
            char j[64]; snprintf(j, sizeof(j), "{\"ota\":\"err\",\"e\":\"%s\"}", otaResultStr(r));
            otaNotify(j);
            otaQuiesce(false);   // failed mid-stream: bring the radios back
        }
    }
};

// Handle the {"ota":{...}} control object from a config write. Kept out of CfgCb::onWrite
// for readability; returns after acting.
static void handleOtaControl(JsonObject o) {
    // Detached image signature (hex DER), pushed on its OWN control message BEFORE begin to
    // keep each JSON small. Store it now; otaFinish verifies it against the baked-in pubkey.
    // Independent of begin/end/abort/confirm - handled first so order on the wire is free.
    if (o["sig"].is<const char*>()) {
        const char* hex = o["sig"].as<const char*>();
        size_t hlen = hex ? strlen(hex) : 0;
        uint8_t der[80];                          // P-256 DER sig is ~70-72 B; bounds it
        if (hlen > 0 && (hlen % 2) == 0 && (hlen / 2) <= sizeof(der) &&
            hexToBytes(hex, der, hlen / 2)) {
            otaSetSignature(der, hlen / 2);
        }
    }
    if (o["begin"].is<bool>() && o["begin"].as<bool>()) {
        uint32_t size = o["size"] | 0u;
        uint32_t crc  = o["crc"].is<const char*>()
                          ? (uint32_t)strtoul(o["crc"].as<const char*>(), nullptr, 16) : 0u;
        const char* ver = o["ver"] | "";
        bool force = o["force"] | false;
        bool quiescedHere = otaQuiesce(true);
        OtaResult r = otaBegin(size, crc, ver, force);
        if (r != OTA_OK) {
            char j[64]; snprintf(j, sizeof(j), "{\"ota\":\"err\",\"e\":\"%s\"}", otaResultStr(r));
            otaNotify(j);
            // Only when this begin owns the quiesce. On OTA_ERR_BUSY the radios belong to the
            // update already streaming, and resuming them here would un-quiesce it mid-flash.
            if (quiescedHere) otaQuiesce(false);
        }
    } else if (o["end"].is<bool>() && o["end"].as<bool>()) {
        OtaResult r = otaFinish();
        // A late-arriving final chunk may still be queued behind this control on the SAME host task.
        // otaFinish returns OTA_PENDING in that case: leave the session (and the radio quiesce) intact
        // and do nothing - the trailing otaWrite completes the image, or the loop watchdog fails it.
        if (r == OTA_PENDING) return;
        if (r == OTA_OK) { delay(250); ESP.restart(); }   // boot the new image
        char j[64]; snprintf(j, sizeof(j), "{\"ota\":\"err\",\"e\":\"%s\"}", otaResultStr(r));
        otaNotify(j);
        otaQuiesce(false);
    } else if (o["abort"].is<bool>() && o["abort"].as<bool>()) {
        otaAbort();
        otaQuiesce(false);
    } else if (o["confirm"].is<bool>() && o["confirm"].as<bool>()) {
        // "ok" is a durable acknowledgement, not merely "the new image is running." A fresh
        // trial must satisfy the product-health gate before otaMarkHealthy can commit and disarm
        // rollback. Tell the app to retry until that succeeds; claiming ok here used to let both
        // apps report completion while a quick power cycle could still revert the board.
        if (otaMarkHealthy()) otaNotify("{\"ota\":\"ok\"}");
        else otaNotify("{\"ota\":\"health-wait\"}");
    }
}

// ---- config writes from the app ----
class CfgCb : public NimBLECharacteristicCallbacks {
    void onWrite(NimBLECharacteristic* c) override {
        // Fail before getValue()/JSON allocation: denied, unauthenticated, or disconnecting links
        // must not copy attacker/app bytes into callback stacks or execute a queued config action.
        if (!gConnected || !gConfigPrivacyReady || !c) return;
        std::string v = c->getValue();
        if (v.empty()) return;
        JsonDocument doc;
        if (deserializeJson(doc, v) != DeserializationError::Ok) return;

        // ECHO ONLY WHEN SOMETHING THE STATUS DOCUMENT REPORTS ACTUALLY MOVED.
        //
        // This handler used to end with an unconditional acabBleUpdateStatus(), so EVERY config
        // write rebuilt and notified the whole status frame - including the writes that change
        // nothing it reports. A connect with full 256-entry ignore and watch lists is 26 staging
        // chunks (20 MACs per write on both platforms) plus the handshake writes, i.e. around
        // thirty back-to-back status notifies drawn from the same 20-block msys pool the
        // replay drain deliberately backs off from with DRAIN_MBUF_MIN - and these have no such
        // guard. They do not LOSE replay records (the drain re-checks os_msys_num_free() every
        // tick and every burst iteration and simply skips), but they spend airtime and slow the
        // drain the user is waiting on. Worse, a pre-commit chunk echoes the STALE ign/wat count,
        // and both apps turn a behind-count into another full list push.
        //
        // The apps reconcile buzzer, alert mode and list state off this echo, so every branch that
        // genuinely mutates a reported field must set the flag - including lat/lon, which flips
        // doc["gps"]. When in doubt, set it: a missing echo desynchronises the app, a spare one
        // only costs a frame.
        bool statusDirty = false;

        // One-shot diagnostic request. Answered on the STATUS characteristic (Config is
        // write-only), NOT here. Handled first and independently of the toggles below so a diag
        // request can never be mistaken for a settings change.
        if (doc["diag"].is<bool>() && doc["diag"].as<bool>()) acabBleSendDiag();

        // Body-cam detector (Axon 00:25:DF). Accept both the new "bodycam" key and
        // the legacy "axon" key, so older app builds keep working.
        if (doc["bodycam"].is<bool>() || doc["axon"].is<bool>()) {
            bool on = doc["bodycam"].is<bool>() ? doc["bodycam"].as<bool>()
                                                : doc["axon"].as<bool>();
            if (on) axonUseRegistryCandidate();   // load 00:25:DF so it actually fires
            axonSetEnabled(on);
            // NOTE: deliberately does NOT touch policeSetEnabled. The broad Motorola
            // match is a SUB-toggle ({"motorola"}) underneath this category, so the
            // category switch no longer clobbers the user's broad-match preference.
            // police_detect gates on axonIsEnabled() anyway, so turning the category
            // off still silences Motorola - it just does not FORGET the sub-setting.
            Serial.printf("[ACAB] Body-cam detector %s\n", on ? "ENABLED" : "disabled");
            statusDirty = true;
        }
        // Broad Motorola Solutions OUI match: sub-toggle of the body-cam category.
        // Lets a user quiet the noisy corporate-OUI proxy while keeping the conf-90
        // Axon BWCDEVICE tag and Utility BodyWorn running.
        if (doc["motorola"].is<bool>()) {
            bool on = doc["motorola"].as<bool>();
            policeSetEnabled(on);
            Serial.printf("[ACAB] Motorola broad-OUI match %s\n", on ? "on" : "off");
            statusDirty = true;
        }
        if (doc["tracker"].is<bool>()) {
            bool on = doc["tracker"].as<bool>();
            trackerSetEnabled(on);
            Serial.printf("[ACAB] Tracker detector %s\n", on ? "on" : "off");
            statusDirty = true;
        }
        if (doc["glasses"].is<bool>()) {      // recording-glasses detector (BLE mfg company ID)
            bool on = doc["glasses"].as<bool>();
            glassesSetEnabled(on);
            Serial.printf("[ACAB] Glasses detector %s\n", on ? "on" : "off");
            statusDirty = true;
        }
        if (doc["flock"].is<bool>()) {        // Flock/ALPR detector (BLE + WiFi)
            bool on = doc["flock"].as<bool>();
            flockSetEnabled(on);
            Serial.printf("[ACAB] Flock/ALPR detector %s\n", on ? "on" : "off");
            statusDirty = true;
        }
        if (doc["drone"].is<bool>()) {        // drone Remote ID detector (BLE + WiFi)
            bool on = doc["drone"].as<bool>();
            droneSetEnabled(on);
            Serial.printf("[ACAB] Drone detector %s\n", on ? "on" : "off");
            statusDirty = true;
        }
        if (doc["droneoui"].is<bool>()) {     // drone vendor-OUI fallback opt-in (default OFF; may false-positive on stationary drone-vendor gear)
            bool on = doc["droneoui"].as<bool>();
            droneOuiSetEnabled(on);
            Serial.printf("[ACAB] Drone OUI fallback %s\n", on ? "on" : "off");
            statusDirty = true;
        }
        if (doc["netcam"].is<bool>()) {       // network-camera opt-in (default OFF; widens WiFi to data frames, see netcam_detect.cpp)
            bool on = doc["netcam"].as<bool>();
            netcamSetEnabled(on);
            Serial.printf("[ACAB] Network-camera detector %s\n", on ? "on" : "off");
            statusDirty = true;
        }
        if (doc["desert"].is<bool>()) {       // Desert mode: report EVERY device in range
            bool on = doc["desert"].as<bool>();
            desertSetEnabled(on);
            Serial.printf("[ACAB] Desert mode %s\n", on ? "ENABLED" : "disabled");
            statusDirty = true;
        }
        if (doc["buzzer"].is<bool>()) {
            bool on = doc["buzzer"].as<bool>();
            alertsSetBuzzerEnabled(on);
            Serial.printf("[ACAB] Buzzer %s\n", on ? "on" : "off");
            statusDirty = true;
        }
        if (doc["led"].is<bool>()) {
            bool on = doc["led"].as<bool>();
            alertsSetLedEnabled(on);
            Serial.printf("[ACAB] LED %s\n", on ? "on" : "off (lights out)");
            statusDirty = true;
        }
        if (doc["volume"].is<int>()) {
            int v = doc["volume"].as<int>();
            if (v < 0) v = 0;
            if (v > 100) v = 100;
            alertsSetVolume((uint8_t)v);
            Serial.printf("[ACAB] Volume %d\n", v);
            statusDirty = true;
        }
        if (doc["ble"].is<bool>()) {
            bool on = doc["ble"].as<bool>();
            acabScannerSetBLE(on);
            Serial.printf("[ACAB] BLE scan %s\n", on ? "on" : "off");
            statusDirty = true;
        }
        if (doc["wifi"].is<bool>()) {
            bool on = doc["wifi"].as<bool>();
            acabScannerSetWiFi(on);
            Serial.printf("[ACAB] WiFi scan %s\n", on ? "on" : "off");
            statusDirty = true;
        }
        if (doc["wifiEco"].is<int>()) {   // 0/3/7/15 s of WiFi RX sleep between sweeps (battery SKU)
            int sec = doc["wifiEco"].as<int>();
            acabScannerSetWifiEco(sec);
            Serial.printf("[ACAB] WiFi eco = %ds\n", acabScannerWifiEco());
            statusDirty = true;
        }
        if (doc["beep"].is<bool>() && doc["beep"].as<bool>()) {
            alertsBeepTest();             // volume preview at the level just set above
        }
        // THE EMPTY-COMMIT RULE. An empty list only commits when EITHER the write says so
        // explicitly with {"clr":true}, OR this peer has already committed a NON-EMPTY list for
        // the same key on this connection.
        //
        // WHY AT ALL. Both apps re-push their whole list on every connect, and an empty commit used
        // to zero the count and rewrite NVS. So a reinstalled app, or any SECOND phone that had
        // never starred anything, silently wiped every star on the board the moment it connected.
        // The watchlist is user-authored data (a starred MAC is a deliberate act, and its label
        // lives only in the app), so losing it is destruction, not something the user can redo from
        // memory.
        //
        // WHY THE SECOND CLAUSE, rather than requiring "clr" outright. Boards update over the air,
        // so the board is routinely NEWER than the app talking to it: an app already in someone's
        // hands does not know about "clr" and would permanently lose the ability to clear a list.
        // That trades a wipe bug for a never-clears bug. But a peer that has already committed a
        // non-empty list this connection has, by definition, already replaced whatever the board
        // held, so letting it then empty that list grants no destructive power it did not just
        // exercise. The wipe case is exactly the one this excludes: an app with nothing to say
        // whose FIRST word on the connection is "empty". Version negotiation would be the obvious
        // alternative and is worse - it needs a version the old app never sends.
        //
        // The flag is per-write like "more", and a chunked write carries at most one of
        // ignore/watch, so one flag serves both without ambiguity.
        const bool listClr = doc["clr"].is<bool>() && doc["clr"].as<bool>();
        // Ignore list. Supports chunking: {"ignore":[...],"more":true} stages more MACs without
        // committing; a chunk with "more" absent/false appends then commits the whole staged list.
        // A single small write with no "more" stages then commits immediately (unchanged behavior).
        if (doc["ignore"].is<JsonArray>()) {
            // An explicit clear means "the list is empty", so a stale staged chunk sequence for
            // THIS key must not survive into the commit below. Per-key on purpose: zeroing both
            // would truncate an in-flight chunk sequence on the other list.
            if (listClr) gIgnoreStageN = 0;
            for (JsonVariant v : doc["ignore"].as<JsonArray>()) {
                if (gIgnoreStageN >= 256) break;
                if (parseMac6(v.as<const char*>(), gIgnoreStage[gIgnoreStageN])) gIgnoreStageN++;
            }
            if (doc["more"].is<bool>() && doc["more"].as<bool>()) {
                Serial.printf("[ACAB] ignore list: staged %d device(s), awaiting more\n", gIgnoreStageN);
            } else if (gIgnoreStageN == 0 && !listClr && !gIgnoreHadContent) {
                Serial.println("[ACAB] ignore list: empty first commit, no clr - keeping the stored list");
            } else {
                acabScannerSetIgnoreList(gIgnoreStage, gIgnoreStageN);
                Serial.printf("[ACAB] ignore list: %d device(s)\n", gIgnoreStageN);
                if (gIgnoreStageN > 0) gIgnoreHadContent = true;
                gIgnoreStageN = 0;
                statusDirty = true;   // "ign" moved; a staging chunk above deliberately does not
            }
        }
        // Watchlist: inverse of the ignore list. Same MAC string format, same 256 cap, same chunked
        // "more" protocol. The app pushes it right after the ignore push on connect; a starred MAC
        // alerts every time it is seen even with no signature match.
        if (doc["watch"].is<JsonArray>()) {
            if (listClr) gWatchStageN = 0;   // see the ignore block
            for (JsonVariant v : doc["watch"].as<JsonArray>()) {
                if (gWatchStageN >= 256) break;
                if (parseMac6(v.as<const char*>(), gWatchStage[gWatchStageN])) gWatchStageN++;
            }
            if (doc["more"].is<bool>() && doc["more"].as<bool>()) {
                Serial.printf("[ACAB] watch list: staged %d device(s), awaiting more\n", gWatchStageN);
            } else if (gWatchStageN == 0 && !listClr && !gWatchHadContent) {
                Serial.println("[ACAB] watch list: empty first commit, no clr - keeping the stored list");
            } else {
                acabScannerSetWatchList(gWatchStage, gWatchStageN);
                Serial.printf("[ACAB] watch list: %d device(s)\n", gWatchStageN);
                if (gWatchStageN > 0) gWatchHadContent = true;
                gWatchStageN = 0;
                statusDirty = true;   // "wat" moved; a staging chunk above deliberately does not
            }
        }
        // Phone GPS from the app: where we are, stamped onto detections + the mesh line.
        if (doc["lat"].is<float>() && doc["lon"].is<float>()) {
            double la = doc["lat"].as<double>(), lo = doc["lon"].as<double>();
            if (la >= -90.0 && la <= 90.0 && lo >= -180.0 && lo <= 180.0) {
                const uint64_t nowUs = (uint64_t)esp_timer_get_time();
                portENTER_CRITICAL(&gGpsMux);
                gPhoneLat = la; gPhoneLon = lo; gPhoneGpsUs = nowUs; gPhoneGpsValid = true;
                // Same write feeds the disconnect-surviving shadow the offline buffer stamps
                // from; see the declaration and ServerCb::onDisconnect.
                gLastPhoneLat = la; gLastPhoneLon = lo;
                gLastPhoneGpsUs = nowUs; gLastPhoneGpsValid = true;
                portEXIT_CRITICAL(&gGpsMux);
                statusDirty = true;   // flips doc["gps"] from false, and refreshes its 60 s window
            }
        }
        // --- offline detection buffer (det_log) ---
        if (doc["buffer"].is<bool>()) {
            bool on = doc["buffer"].as<bool>();
            if (on) detLogSetEnabled(true);
            else disableReplayLog();
            Serial.printf("[ACAB] Offline buffer %s\n", on ? "ENABLED" : "disabled");
            statusDirty = true;
        }
        // "Record everything": also buffer uncategorized nearby devices, and re-arm capture on a
        // timer, so a board left unattended can answer "did anything come by at all" instead of
        // only "did a KNOWN signature come by". Deploy-and-leave only. See the long note in
        // det_log.h, including the auto-wipe tradeoff the app must surface where the user flips it.
        if (doc["bufall"].is<bool>()) {
            bool on = doc["bufall"].as<bool>();
            detLogSetBufferAll(on);
            Serial.printf("[ACAB] Offline buffer: record-everything %s\n", on ? "ENABLED" : "disabled");
            statusDirty = true;
        }
#ifdef ACAB_CAPTURE_BUILD
        // {"mark":"<label>"} - ground-truth marker for field validation. CAPTURE BUILDS ONLY, and
        // that is the point: it exists to justify signatures, not to be one. It changes no
        // classification, emits no detection and returns nothing to the app; the output goes to
        // the serial capture. Ignored entirely by a shipping build, so an app that sends it to a
        // production board simply gets no effect rather than an error.
        if (doc["mark"].is<const char*>()) acabScannerMark(doc["mark"].as<const char*>());
#endif
        // Process explicit clear before a key in the same object. It is the user's destructive
        // ownership-transfer authorization; an ordinary multi-bond handshake must never erase a
        // nonempty generation merely because phone B has a different app-installation key.
        if (doc["clearlog"].is<bool>() && doc["clearlog"].as<bool>()) {
            gSessionKeyReplacementApproved = true;
            clearReplayLog();
            Serial.println("[ACAB] Offline buffer erased");
            statusDirty = true;   // "buf" -> 0, "wiping" -> true, "bufsat" cleared
        }
        if (doc["key"].is<const char*>()) {            // 64 hex chars -> 32-byte at-rest key
            uint8_t k[32] = {};
            if (hexToBytes(doc["key"].as<const char*>(), k, 32)) {
                const DetLogKeyResult keyResult =
                    installReplayKey(k, gSessionKeyReplacementApproved);
                // Replay authorization belongs to THIS authenticated session, not to whatever key
                // happens to remain in det_log RAM from a prior bonded phone. Only a verified key
                // that det_log installed or safely staged proves that boundary. PENDING/REJECTED
                // fail closed; MISMATCH additionally tells the app that explicit clear is required.
                gSessionReplayKeySupplied = keyResult == DET_LOG_KEY_ACCEPTED;
                gSessionKeyMismatch = keyResult == DET_LOG_KEY_MISMATCH;
                if (keyResult == DET_LOG_KEY_MISMATCH) {
                    // This peer has not proved ownership of the retained generation. Drop even a
                    // GPS fix parsed earlier in this same JSON object; later writes are cleared at
                    // disconnect unless this session eventually supplies an accepted key.
                    clearPhoneGpsShadow(true);
                }
                if (keyResult == DET_LOG_KEY_ACCEPTED)
                    gSessionKeyReplacementApproved = false;
                // Status storage survives links. Rebuild on EVERY valid key offer so an accepted
                // KA clears a prior session's keymis:true just as promptly as KB sets it.
                statusDirty = true;
                Serial.printf("[ACAB] Offline buffer key result=%u\n", (unsigned)keyResult);
            }
            zeroSecret(k, sizeof(k));
        }
        if (doc["epoch"].is<uint32_t>()) detLogSetEpoch(doc["epoch"].as<uint32_t>());
        if (doc["sync"].is<uint32_t>()) {
            // seq values restart after a clear. Missing/invalid syncgen therefore means legacy or
            // unknown state and intentionally requests the full retained window; only an exact
            // durable generation match is allowed to resume at the supplied cursor.
            const uint32_t syncGeneration = doc["syncgen"].is<uint32_t>()
                ? doc["syncgen"].as<uint32_t>() : 0;
            if (!gSessionReplayKeySupplied) {
                // Retained KA may still be needed for phone A's next reconnect, but it proves
                // nothing about this peer. Never emit even a begin envelope until this session has
                // supplied a key det_log accepted against the published generation.
                stopReplaySession();
                Serial.println("[ACAB] Offline replay denied: current session key not accepted");
            } else {
                startReplaySession(doc["sync"].as<uint32_t>(), syncGeneration);
            }
        }
        // Dual-radio black box on the nRF: replay its records, or wipe it (seizure-aware).
        if (doc["bbdump"].is<bool>()  && doc["bbdump"].as<bool>())  acabScannerSendCoProcCmd("DUMP");
        if (doc["bbclear"].is<bool>() && doc["bbclear"].as<bool>()) acabScannerSendCoProcCmd("BCLR");
        // The stock legacy nRF bootloader cannot authenticate an image. In addition to the app's
        // signed-package verification, require the encrypted bonded link and the short RAM-only
        // physical-start window before arming it. The drain re-checks both so a delayed request
        // cannot escape the session that authorized it.
        if (doc["nrfdfu"].is<bool>() && doc["nrfdfu"].as<bool>()) {
            if (nrfDfuMayArmNow() && gLinkActions.arm(AcabLinkActionSlot::nrfDfu)) {
                otaNotify("{\"ota\":\"nrf-ready\"}");
            } else {
                Serial.println("[nrf] DFU denied: power-cycle, reconnect securely, then retry");
                otaNotify("{\"ota\":\"nrf-denied\",\"e\":\"physical\"}");
            }
        }
        // App power-off ({"poweroff":true}). Latch ONLY - the real deep-sleep shutdown runs from the
        // beacon-board loop(), never here: powerOffDeepSleep blocks on the nRF park handshake and then
        // never returns, which on the NimBLE host task would freeze the whole BLE stack. The rev-B gate
        // and the mid-OTA guard are applied by the loop drain. The {"pwr":"off"} heads-up to the app is
        // sent from powerOffDeepSleep itself, and ONLY when the board is genuinely about to drop - so a
        // board that ignores this key (older firmware) never tells the app "off", and the app therefore
        // never mis-arms its intentional-disconnect flag against a board that will keep running.
        if (doc["poweroff"].is<bool>() && doc["poweroff"].as<bool>()) {
            if (!gLinkActions.arm(AcabLinkActionSlot::powerOff)) {
                Serial.println("[pwr] request denied: deferred link-action lease unavailable");
            }
        }
        // Firmware update control. Handled last: an {"ota":{"end"}} reboots the board.
        // An OTA begin QUIESCES both radios and every failure path restores them (otaQuiesce),
        // so this branch moves doc["ble"] / doc["wifi"] even though it never names them.
        if (doc["ota"].is<JsonObject>()) { handleOtaControl(doc["ota"].as<JsonObject>()); statusDirty = true; }
        // Deliberately NOT dirty, and each for its own reason: {"diag"} answers on its own frame;
        // {"beep"} is a sound, not a setting; {"epoch"} and {"sync"} touch no reported field (and
        // {"sync"} fires at the exact moment the drain starts, which is the worst moment to spend
        // an unnecessary notify); a "more":true staging chunk has not committed anything yet;
        // {"mark"} is capture-build ground truth; {"bbdump"}/{"bbclear"}/{"nrfdfu"}/{"poweroff"}
        // only hand work to another task or radio, and whatever they change shows up in the next
        // ~5 s periodic status anyway.
        if (statusDirty) acabBleUpdateStatus();
    }
};

void acabBleBegin(const char* deviceName, const char* fwLabel, bool startAdvertising) {
    gFwLabel = fwLabel ? fwLabel : "ACAB-ouispy";
    if (!gLinkActions.initialize()) {
        Serial.println("[ACAB] deferred link-action lease init failed; commands disabled");
    }
    if (!gJsonMux) gJsonMux = xSemaphoreCreateMutex();   // guards the shared JSON scratch pool
    if (!gNotifyMux) gNotifyMux = xSemaphoreCreateMutex();   // serializes every setValue+notify pair
    if (!gReplayMux) gReplayMux = xSemaphoreCreateMutex();   // host callbacks vs replay burst; see ReplayLock
    if (!gOtaQuiesceMux) gOtaQuiesceMux = xSemaphoreCreateMutex();   // host task vs loop task, see otaQuiesce

    NimBLEDevice::init(deviceName ? deviceName : "ACAB");
    NimBLEDevice::setCustomGapHandler(acabGapTap);   // raw reason codes, see acabGapTap

// PER-UNIT IRK: DESIGNED, IMPLEMENTED, AND REVERTED. Read this before trying it again.
//
// NimBLE installs a HARDCODED DEFAULT IRK (ble_hs_pvcy_default_irk, a public constant sitting in
// this repo's own libdeps) unless told otherwise, so every board ships the same identity key. That
// is a real weakness and it is UNFIXED: a listener holding that published constant can resolve any
// unit's rotating address, and two boards bonded to one phone can resolve to each other.
//
// The obvious fix, 16 random bytes in NVS installed with ble_hs_pvcy_set_our_irk, was built and
// then removed because it BREAKS PAIRING ON EVERY BOOT. Traced through the pinned NimBLE 1.4.3:
//   ble_hs_pvcy_irk[16] is file-static BSS, so it reads as zero on every boot and the "is this a
//   new IRK" memcmp in ble_hs_pvcy_set_our_irk ALWAYS differs. That runs
//   ble_hs_resolv_list_clear_all(), which zeroes the resolving list (discarding the bonded peers
//   ble_hs_misc_restore_irks just restored during sync) and calls ble_rpa_peer_dev_rec_clear_all(),
//   which calls ble_store_persist_peer_records() - so the peer records are deleted FROM NVS.
//   A bonded phone then connects from an RPA nothing can resolve, the LTK lookup misses, encryption
//   fails, and every characteristic here is READ_ENC/WRITE_ENC, so the app gets nothing. Re-pairing
//   works only until the next power cycle, forever.
//
// Doing it properly means rebuilding peer_dev_rec from the bond store and re-running
// ble_hs_misc_restore_irks after the install, both private host APIs, and it must be proven on a
// BONDED board across a power cycle before it ships. Restoring the resolving list alone is not
// enough: the connect path reads peer_dev_rec, and ble_hs_resolv_list_add only updates records that
// already exist, it never creates them.
//
// Until then the shared default IRK stands, and the privacy claim must be stated honestly: the
// address rotates, which defeats casual correlation, but it is NOT unlinkable to anyone who knows
// the NimBLE constant.
    NimBLEDevice::setMTU(512);   // roomy ATT payload: the status + rich drone JSON outgrew 247 (see NOTIFY_MAX)
    // Encrypted, bonded link for the whole service, so a stranger can't silence the
    // scanner (config write) or watch what you're detecting (detection/status stream).
    // Pairing is "Just Works" (no passkey) because the board has no display/keypad, so
    // there is NO MITM protection AT THE ONE-TIME BOND: an active attacker present during
    // that first pairing could interpose. Passive sniffers and later unbonded strangers
    // are fully shut out regardless. THREAT-MODEL NOTE: first-pair the board in a trusted
    // RF environment (not in public) - a no-I/O device can't do better without OOB pairing.
    NimBLEDevice::setSecurityAuth(true, false, true);            // bonding, no MITM, LE Secure Connections
    NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
    // DISTRIBUTE THE IRK EXPLICITLY (BLE_SM_PAIR_KEY_DIST_ID), do not inherit a default.
    //
    // This is what makes address privacy WORK rather than break pairing. Under ACAB_BLE_PRIVACY
    // below, the board advertises a Resolvable Private Address that rotates. A bonded phone can
    // only follow that rotation if it holds our Identity Resolving Key, and it only holds the IRK
    // if we handed it over during bonding. Rely on whatever NimBLE's default key distribution
    // happens to be and the outcome is version-dependent: on a build that omits ID, every rotation
    // looks like a brand-new stranger and the paired phone stops reconnecting.
    //
    // Stated as its own call so it is impossible to change the privacy setting without seeing this.
    NimBLEDevice::setSecurityInitKey(BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID);
    NimBLEDevice::setSecurityRespKey(BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID);

#if ACAB_BLE_PRIVACY
    // ADDRESS PRIVACY. Advertise a Resolvable Private Address that rotates, instead of a fixed
    // one that persists across reboots.
    //
    // WHY A COUNTER-SURVEILLANCE DEVICE OF ALL THINGS NEEDS THIS: the detection path is genuinely
    // passive and always was, but the phone link had to exist, and it was broadcasting a stable
    // address forever. That makes a unit a persistent, trackable identity - the same beacon at a
    // protest on Tuesday and a courthouse on Friday is provably the same device to anyone with a
    // cheap dongle. It is precisely the harm this product's own tracker detection exists to warn
    // people about, pointed back at its owner. Our own drive tests recorded boards detecting each
    // other, which is that enumeration working by accident.
    //
    // A bonded phone follows the rotation using the IRK distributed above; strangers cannot.
    //
    // *** BENCH BEFORE PUBLISHING. NOT A DESK CHANGE. ***
    // Existing bonds were made BEFORE the explicit IRK distribution above, so a phone paired to an
    // older build may not hold our IRK and may need to forget-and-re-pair ONCE after this update.
    // That is recoverable, not a brick, but it must be a known cost rather than a surprise.
    // Required sequence on real hardware before this reaches anyone:
    //   1. flash one board, confirm an ALREADY-BONDED phone still reconnects (or note that it does
    //      not, and that re-pairing is therefore required for existing users)
    //   2. confirm a FRESH pair works end to end on both iOS and Android
    //   3. confirm the board still appears in the app's picker across an address rotation
    // BLE_OWN_ADDR_RANDOM (0x01), NOT BLE_OWN_ADDR_RPA_PUBLIC_DEFAULT (0x02). This distinction is
    // the whole feature and it is invisible from the board.
    //
    // 0x02 asks the CONTROLLER to generate an RPA from its resolving list. Under HOST-based
    // privacy NimBLE keeps that list in a host-side array and never sends HCI LE Add Device To
    // Resolving List, so the controller's list is empty, and per Core Spec Vol 4 Pt E 7.8.5 an
    // empty list under 0x02 means the controller falls back to THE PUBLIC ADDRESS. The board then
    // advertises its fixed factory MAC exactly as before, while ble_hs_pvcy_rpa_config has
    // genuinely installed a rotating RPA as the controller's RANDOM address, which nothing reads.
    //
    // 0x01 advertises that random address, which IS the RPA the host installed and keeps
    // re-rolling. NimBLE-Arduino routes both cases through the same ble_hs_pvcy_rpa_config, so
    // nothing else changes. ble_hs_pvcy.h states this outright: "2. Set own_addr_type to
    // BLE_OWN_ADDR_RANDOM."
    //
    // The first attempt used 0x02 and the serial diagnostic below printed a rotating address, so
    // it read as working. It was not: the diagnostic proves an RPA was GENERATED, never that it
    // was ADVERTISED. Do not treat that line as on-air proof.
    NimBLEDevice::setOwnAddrType(BLE_OWN_ADDR_RANDOM);
#endif
#ifdef ESP_PWR_LVL_P9
    NimBLEDevice::setPower(ESP_PWR_LVL_P9);
#endif

    gServer = NimBLEDevice::createServer();
    gServer->setCallbacks(new ServerCb());

    NimBLEService* svc = gServer->createService(ACAB_BLE_SVC_UUID);
    gDetChar  = svc->createCharacteristic(ACAB_BLE_DET_UUID,
                    NIMBLE_PROPERTY::NOTIFY | NIMBLE_PROPERTY::READ_ENC);
    gCfgChar  = svc->createCharacteristic(ACAB_BLE_CFG_UUID,
                    NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_ENC);
    gStatChar = svc->createCharacteristic(ACAB_BLE_STAT_UUID,
                    NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY | NIMBLE_PROPERTY::READ_ENC);
    // UAF guard: pre-grow gStatChar's value buffer to STATUS_JSON_MAX now, before any client can
    // connect. NimBLE's setValue reallocs-to-grow OUTSIDE its read critical section
    // (NimBLEAttValue.h), so a growth realloc racing a peer ATT READ is a use-after-free.
    //
    // The warm must match the SERIALIZATION BUFFER, not the notify cap. It used to be NOTIFY_MAX
    // (500) on the premise that every frame is <= NOTIFY_MAX, and that premise was wrong: only
    // the notify() is size-gated, while the periodic status writer serializes into a
    // STATUS_JSON_MAX buffer and setValues the result, so a READ is served from whatever that
    // writer last stored. (acabBleSendDiag shares the constant only because it shares the
    // characteristic; it never setValues, so it is not part of this race - see the banner there.)
    // A 501..512 byte frame - reachable on a dual-radio rev-B board carrying the long
    // counters plus bufall/bufsat/buferr/sdrop/wiping/nrfup/chg/ledon - therefore grew the value
    // past the warmed capacity and reallocated it, which is exactly the race the warm exists to
    // prevent. Capacity only ever ratchets UP in NimBLE, so warming to STATUS_JSON_MAX means no
    // later setValue on this characteristic can move the block again.
    //
    // The other half of the same fix, and the reason "a READ is served from what the writer last
    // stored" is NOT the same as "a READ always returns the freshest status": acabBleUpdateStatus
    // now REFUSES to setValue any frame that reaches STATUS_JSON_MAX (its scratch is deliberately
    // one byte larger so the overflow is visible - see the constant). An overflowing build leaves
    // the previous complete frame in place, which is the right trade against publishing a
    // truncated document, but it means a stale READ is a state this code can reach: a board whose
    // every build overflows keeps serving its last good frame, and one that overflows on the first
    // build of a boot keeps serving the "{}"-plus-spaces placeholder below.
    // The placeholder is valid empty JSON ("{}" + trailing spaces) so a read landing before the
    // first real status still decodes clean.
    { uint8_t warm[STATUS_JSON_MAX]; memset(warm, ' ', sizeof(warm)); warm[0] = '{'; warm[1] = '}';
      gStatChar->setValue(warm, sizeof(warm)); }
    // OTA: image bytes arrive here (write-no-response, encrypted); progress notifies back.
    gOtaChar  = svc->createCharacteristic(ACAB_BLE_OTA_UUID,
                    NIMBLE_PROPERTY::WRITE_NR | NIMBLE_PROPERTY::WRITE |
                    NIMBLE_PROPERTY::WRITE_ENC | NIMBLE_PROPERTY::NOTIFY);
    gOtaChar->setCallbacks(new OtaCb());
    gCfgChar->setCallbacks(new CfgCb());
    otaSetNotifier(otaNotify);
    svc->start();

    NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
    adv->addServiceUUID(ACAB_BLE_SVC_UUID);
    adv->setScanResponse(true);

    NimBLEAdvertisementData scanResp;
    scanResp.setName(deviceName ? deviceName : "ACAB");

#if ACAB_ADVERTISE_VERSION
    // LEGACY, DEFAULT OFF. The exact firmware version used to ride the scan response so the app
    // could show it in the picker before connecting. That published the unit's CAPABILITY to
    // every passive listener - which signature set it carries, therefore what it can and cannot
    // see - to save its owner one tap. The version is already in the Status characteristic, which
    // is post-connect and post-bond, so nothing is lost but the pre-connect convenience.
    std::string verData;
    verData.push_back((char)0xAB);          // company id 0xACAB (LE) - our own marker
    verData.push_back((char)0xAC);
    verData += ACAB_FW_VERSION;             // e.g. "0.2.3"
    scanResp.setManufacturerData(verData);
#endif

    adv->setScanResponseData(scanResp);
    // DEFERRABLE. beacon-board passes false and starts advertising itself AFTER the soft-power gate
    // and after the pairing gate is configured. Previously the radio went live here, ~160 lines
    // before the board decided whether this boot even stays on and ~230 before enforcement was
    // configured, so a phone could connect in that gap with the gate still false - including during
    // a boot that ends in powerOffDeepSleep(). Default true keeps mesh-detect's call site unchanged.
    if (startAdvertising) {
        adv->start(0, advCompleteCb);
        gAdvIntended = true;
    }

    acabBleUpdateStatus();
    Serial.printf("[ACAB] BLE service up%s\n",
                  startAdvertising ? ", advertising" : " (advertising deferred)");
    // Report the advertised address and whether privacy is on. This is the ONLY way to verify the
    // RPA change from a laptop: macOS and iOS never hand a peer's MAC to an application, they
    // substitute a per-host UUID, so a scan from a development machine cannot tell a rotating
    // address from a fixed one. The board has to say it itself. Two boots printing two different
    // addresses is the evidence that privacy is actually engaged rather than silently ignored.
    // getAddress() is hardcoded to BLE_ADDR_PUBLIC in NimBLE-Arduino, so it reports the IDENTITY
    // address and CANNOT tell you whether an RPA is being advertised. The load-bearing fact is
    // whether the host privacy code was compiled in at all: ble_hs_pvcy_rpa_config() sits behind
    // #if MYNEWT_VAL(BLE_HOST_BASED_PRIVACY), which on ESP32-S3 resolves to
    // CONFIG_BT_NIMBLE_HOST_BASED_PRIVACY. Without it, setOwnAddrType() silently does nothing but
    // set a member variable, and a build that LOOKS correct advertises a fixed address forever.
    // Tested on hardware 2026-08-01: two boots printed the identical factory address.
    // Guarded with defined() because the symbol is genuinely absent, not zero, in a stock build,
    // so a bare MYNEWT_VAL() here is a compile error rather than a false reading.
#if defined(CONFIG_BT_NIMBLE_HOST_BASED_PRIVACY) && CONFIG_BT_NIMBLE_HOST_BASED_PRIVACY
    const char* kPrivCompiled = "YES";
#else
    const char* kPrivCompiled = "NO - RPA IS A NO-OP IN THIS BUILD";
#endif
    // Ask the host for BOTH identity kinds. getAddress() only ever reports the PUBLIC one, so on
    // its own it cannot distinguish a private build from a fixed one. When host privacy is live
    // NimBLE configures a random address as well, and its presence plus its top two bits are the
    // closest thing available WITHOUT A SNIFFER, and it is not on-air proof: 01 = resolvable private (the
    // rotating kind privacy is supposed to produce), 11 = static random, 00 = non-resolvable.
    ble_addr_t rnd; bool haveRnd = (ble_hs_id_copy_addr(BLE_ADDR_RANDOM, rnd.val, NULL) == 0);
    char rndStr[24] = "none";
    const char* rndKind = "-";
    if (haveRnd) {
        snprintf(rndStr, sizeof(rndStr), "%02x:%02x:%02x:%02x:%02x:%02x",
                 rnd.val[5], rnd.val[4], rnd.val[3], rnd.val[2], rnd.val[1], rnd.val[0]);
        switch (rnd.val[5] >> 6) {
            case 0b01: rndKind = "RESOLVABLE-PRIVATE (rotates)"; break;
            case 0b11: rndKind = "static-random";                break;
            case 0b00: rndKind = "non-resolvable-private";       break;
            default:   rndKind = "?";                            break;
        }
    }
    Serial.printf("[ACAB] BLE public=%s | random=%s (%s) | privacy requested=%s compiled=%s\n",
                  NimBLEDevice::getAddress().toString().c_str(), rndStr, rndKind,
                  ACAB_BLE_PRIVACY ? "yes" : "no", kPrivCompiled);
}

// ---- REPLAY TRIM LADDER (small-MTU peers) ----------------------------------------------------
// DEGRADE, DO NOT DROP, applied to the offline-buffer replay - the same rule the live path has
// followed since detect_elide.h, and for a sharper reason: a live sighting that will not fit is
// one missed alert from a device that is usually still transmitting, while a replay record is
// evidence. detLogPeekForDrain leaves its cursor parked until a fitting frame has been handed to
// notify and detLogCommitDrain succeeds, so no size/schema failure can consume an unseen row.
//
// The live path's elide order buys nothing here: StoredDet persists none of the elidable RID
// fields, so a replay frame is mandatory fields only. These five steps are what a replay frame
// actually has to give up, cheapest first. They apply ONLY when the full frame exceeds the peer's
// notifyCap(), so an Android link (MTU 512) still gets every field, unchanged.
//
//   HIST_TRIM_NEW    drop "new". It is always false on a replay row, and both apps default it to
//                    false when the key is absent. Costs nothing at all.
//   HIST_TRIM_ANCHOR drop "ms"/"boot", but ONLY when "at" is resolved: they are the raw inputs
//                    the app uses to VERIFY or redo a reconstruction the board already did, so
//                    losing them on an anchored row costs a cross-check and (on iOS) this row's
//                    contribution to that boot's anchored span. An APPROX row keeps them, because
//                    for an unanchored boot they are the only dating information that exists.
//   HIST_TRIM_NAME   drop "name". StoredDet's truncated 6-char label; "t" still carries the class
//                    and "mac" the identity.
//   HIST_TRIM_FIX    drop "lat", "lon" AND "gage" - the last quality rung before the bounded
//                    identity fallback. Both halves of that are load-bearing; see below.
//   HIST_TRIM_ID     last-resort bounded core: drop the stored UAS ID. The drone remains a real
//                    history row keyed by t/mac/seq, but loses its rotation-stable identity. This
//                    is cheaper than losing the row and makes the remaining envelope independent
//                    of attacker-controlled string escaping.
//
// "GAGE" LEAVES WITH THE COORDINATE, NEVER BEFORE IT. It used to be step 2, ahead of the two keys
// it qualifies, and that made a small-MTU replay actively misleading rather than merely short. A
// buffered non-drone position is ALWAYS a stale phone fix - up to DET_LOG_GPS_MAX_AGE_MS, about
// 18h12m - and "gage" is the only thing that says so. Both apps gate their staleness wording on
// it (Detection.gpsFixAgeMagnitude returns nil with no gpsAgeSec, so "fix 4m" and "location from
// a fix 4m old" never render), and a coordinate arriving without it therefore reads as a pin
// taken on the spot. The old order produced that confident lie on exactly the rows the offline
// buffer exists to create, and on iPhones only, since an Android link at MTU 512 never trims at
// all. Tying the three keys to one step makes an unqualified stale coordinate unrepresentable.
//
// POSITION IS THE LAST QUALITY RUNG, because with "gage" bound to it this step costs more context
// than the earlier metadata rungs. The anchor pair is a cross-check on a time the app already has, and "name" is a
// 6-char truncation of a label whose class is already in "t" and whose identity is already in
// "mac"; WHERE something was heard is the half of a deploy-and-leave capture the buffer was added
// to recover. Ordering it after those two also means an anchored GPS-stamped row now gives up only
// "new" and the anchor pair, and keeps a properly qualified position, where the old ladder took
// the qualifier away first. HIST_TRIM_ID follows only as the guaranteed-size alternative to
// losing the entire row.
//
// One knock-on, in the right direction: a drone row's "lat"/"lon" is the aircraft's own broadcast
// position and carries no "gage", so the old step 2 could not shrink it and was skipped. An
// UNANCHORED drone row (ms/boot cannot go) could therefore exhaust the whole ladder and still be
// destroyed by the transport. It now gives up position, then (only if still necessary) the UAS ID.
// Losing where/which aircraft was there is bad; losing that a drone was there at all is worse.
//
// Measured against an iPhone link (MTU 185 -> notifyCap 182): a FULL ALPR row with a GPS stamp is
// 211 B and a full drone row with a 19-char UAS id is 212 B. Both were lost outright before this
// ladder existed. The per-step byte counts that used to be quoted here were measured against the
// old order and are not restated, because the steps no longer shed the same keys.
// The final core has no attacker-controlled variable-length field. At the widest legal value for
// every retained integer, an UNANCHORED row is 159 B of compact JSON; an anchored row is shorter.
// That is a hard guarantee under the iPhone-class 182 B cap, not a measurement of one fixture.
// Keep the source-parsing host budget beside this constant in test_acab_ble_service.cpp.
static const size_t HIST_MIN_ENVELOPE_WORST = 159;
static_assert(HIST_MIN_ENVELOPE_WORST <= 182,
              "minimal replay envelope must fit an iPhone-class 182-byte notify payload");

enum : uint8_t {
    HIST_TRIM_NONE = 0,
    HIST_TRIM_NEW,
    HIST_TRIM_ANCHOR,
    HIST_TRIM_NAME,
    HIST_TRIM_FIX,
    HIST_TRIM_ID,
    HIST_TRIM_MAX
};

// The final replay rung is deliberately a fixed-format envelope rather than another generic JSON
// rebuild. That makes its cap guarantee structural: no later optional AcabDetection field can
// accidentally leak back into this path and widen it. Every substituted value is numeric except
// the fixed-width, already-formatted MAC. The unanchored variant is the wider one at 159 bytes;
// test_acab_ble_service.cpp independently fills every integer with its widest legal value.
static size_t serializeMinimalReplay(const AcabDetection& d, const char* macStr, char* buf,
                                     size_t bufsz, uint32_t seq, uint32_t atUnix,
                                     uint32_t whenMs, uint32_t bootCount) {
    const int n = atUnix
        ? snprintf(buf, bufsz,
                   "{\"t\":%u,\"s\":%u,\"meth\":%u,\"c\":%u,\"mac\":\"%s\",\"rssi\":%d,"
                   "\"n\":%u,\"hist\":true,\"seq\":%u,\"at\":%u}",
                   (unsigned)d.type, (unsigned)d.src, (unsigned)d.method,
                   (unsigned)d.confidence, macStr, (int)d.rssi, (unsigned)d.count,
                   (unsigned)seq, (unsigned)atUnix)
        : snprintf(buf, bufsz,
                   "{\"t\":%u,\"s\":%u,\"meth\":%u,\"c\":%u,\"mac\":\"%s\",\"rssi\":%d,"
                   "\"n\":%u,\"hist\":true,\"seq\":%u,\"approx\":true,\"ms\":%u,\"boot\":%u}",
                   (unsigned)d.type, (unsigned)d.src, (unsigned)d.method,
                   (unsigned)d.confidence, macStr, (int)d.rssi, (unsigned)d.count,
                   (unsigned)seq, (unsigned)whenMs, (unsigned)bootCount);
    return n > 0 ? (size_t)n : 0;
}

// Build a detection record into `buf` (returns length). For replay set hist=true and
// pass seq + atUnix (atUnix==0 -> "approx":true), plus whenMs/bootCount so the app can verify or
// redo the time reconstruction and bracket an unanchored boot. NOTE: mirrors the field set in
// acabBleNotifyDetection below - keep the two in sync (or consolidate later).
// `elide` trims optional RID enrichment for a small-MTU live notify; see detect_elide.h for the
// order and why. 0 (the default) is the full record. `trim` is the REPLAY-side equivalent and is
// ignored unless hist is true; see the HIST_TRIM ladder just above for what each step costs.
// The two never overlap: a replayed record carries none of the elidable RID fields (StoredDet
// does not persist them), and a live record has no hist envelope to trim.
static size_t serializeDetection(const AcabDetection& d, bool isNew, char* buf, size_t bufsz,
                                 bool hist, uint32_t seq, uint32_t atUnix,
                                 uint32_t whenMs = 0, uint32_t bootCount = 0,
                                 uint8_t elide = ACAB_ELIDE_NONE,
                                 uint8_t trim = HIST_TRIM_NONE) {
    char macStr[18];
    acabFormatMac(d.mac, macStr);
    if (hist && trim >= HIST_TRIM_ID)
        return serializeMinimalReplay(d, macStr, buf, bufsz, seq, atUnix, whenMs, bootCount);
    JsonPoolLock jp;
    JsonDocument doc(jp.alloc());
    doc["t"]    = (int)d.type;
    doc["s"]    = (int)d.src;
    doc["meth"] = (int)d.method;
    doc["c"]    = d.confidence;
    doc["mac"]  = macStr;
    doc["rssi"] = d.rssi;
    const bool histTrim = hist && trim > HIST_TRIM_NONE;   // replay ladder, see HIST_TRIM above
    if (d.name[0] && !(histTrim && trim >= HIST_TRIM_NAME)) doc["name"] = d.name;
    if (d.id[0] && !(histTrim && trim >= HIST_TRIM_ID)) doc["id"] = d.id;
    if (d.detail[0]) doc["det"]  = d.detail;
    // BLE mfg-specific company ID, for diagnosability (ble-protocol.md): the glasses and tracker
    // detectors key on it, so the detail screen can show which company ID the board actually saw.
    if (d.companyId && acabElideKeeps(ACAB_FIELD_CID, elide)) doc["cid"] = d.companyId;
    // The position and its age share ONE trim step, so a coordinate can never outlive the key that
    // says how stale it is. See the HIST_TRIM ladder above.
    if ((d.lat || d.lon) && !(histTrim && trim >= HIST_TRIM_FIX))
                                  { doc["lat"]  = d.lat;  doc["lon"]  = d.lon; }
    if (d.gpsAgeMs && !(histTrim && trim >= HIST_TRIM_FIX))
        doc["gage"] = (uint32_t)(d.gpsAgeMs / 1000);   // GPS fix age (s)
    if ((d.pilotLat || d.pilotLon) && acabElideKeeps(ACAB_FIELD_PILOT, elide)) {
        doc["plat"] = d.pilotLat; doc["plon"] = d.pilotLon;
    }
    if (d.altitude)  doc["alt"]  = d.altitude;   // aircraft altitude is NOT elidable
    if (d.speedH   && acabElideKeeps(ACAB_FIELD_SPD,  elide)) doc["spd"]  = (int)d.speedH;
    if (d.speedV   && acabElideKeeps(ACAB_FIELD_VSPD, elide)) doc["vspd"] = (int)d.speedV;
    if (d.heading  && acabElideKeeps(ACAB_FIELD_HDG,  elide)) doc["hdg"]  = (int)d.heading;
    if (d.heightAGL&& acabElideKeeps(ACAB_FIELD_HGT,  elide)) doc["hgt"]  = (int)d.heightAGL;
    if (d.pilotAlt && acabElideKeeps(ACAB_FIELD_PALT, elide)) doc["palt"] = d.pilotAlt;
    if (d.ridStatus&& acabElideKeeps(ACAB_FIELD_STA,  elide)) doc["sta"]  = d.ridStatus;
    doc["n"]   = d.count;
    if (!(histTrim && trim >= HIST_TRIM_NEW)) doc["new"] = isNew;
    if (hist) {
        doc["hist"] = true;
        doc["seq"]  = seq;
        if (atUnix) doc["at"] = atUnix; else doc["approx"] = true;
        // The raw reconstruction inputs, normally sent whether or not the board could resolve "at"
        // itself. "at" is never a clock reading: the board has no RTC, so it is always derived from
        // a per-boot anchor. Shipping the inputs lets the app verify that derivation, redo it
        // against its own anchor history (which outlives board reboots and factory resets), and
        // bracket a record whose boot was never anchored instead of showing a bare "time unknown".
        //
        // HIST_TRIM_ANCHOR gives them up on a small-MTU peer, and ONLY when "at" is resolved: then
        // they are a cross-check on a time the app already has. When "at" is absent this row IS the
        // unanchored case the inputs exist for, so they stay and the row rides the ladder's other
        // steps instead.
        if (!(atUnix && histTrim && trim >= HIST_TRIM_ANCHOR)) {
            doc["ms"]   = whenMs;
            doc["boot"] = bootCount;
        }
    }
    return serializeJson(doc, buf, bufsz);
}

// Drive the offline-buffer replay: a bounded burst per call, paced by loop(). On {sync}
// the app starts a drain; we stream each stored record tagged hist/seq/at, then a
// {"hist":"end","n":N} sentinel so the app can spot drops and re-sync from its lastSeq.
// Also pumps the acab_core deferred work that must run off the NimBLE host task.
void acabBleDrainTick() {
    // Pumps first, BEFORE the connectivity guard: a latched buffer wipe must finish even if
    // the phone that triggered it walks away (one 64KB block per pass), and an in-flight nRF
    // ignore-mirror stream must complete after a disconnect too.
    detLogEraseTick();
    acabScannerMirrorTick();

    // ADVERTISING SUPERVISOR, belt and braces to advCompleteCb above. A board that has silently
    // stopped advertising is indistinguishable from a dead board to the user, and this class of
    // stop is not unique to RPA rotation: any future preemption, a controller reset, or a start()
    // that fails transiently would strand it the same way. Cheap enough to run unconditionally
    // (one bool read on a tick loop() already calls), and it covers the window where a preemption
    // lands while the callback pointer is momentarily unset. Rate-limited so a genuinely failing
    // start() cannot spin, and it logs, because a board recovering itself in silence teaches
    // nobody anything.
    // Drop an unauthenticated link promptly. Besides bounding an SMP resource hold, this keeps a
    // raw connection from parking the radio indefinitely. The physical pairing decision is
    // re-evaluated so a stranger cannot connect just before the window closes and authenticate
    // later. Offline logging continues throughout this state because gConnected remains false.
    if (gLinkConnected && !gConnected) {
        const uint32_t elapsed = (uint32_t)(millis() - gAuthStartedMs);
        if (!acabPairPreAuthMayContinue(gPairGateEnabled,
                                        gBoardHadBondAtConnect,
                                        gPeerKnownAtConnect,
                                        acabBlePairWindowOpen(),
                                        elapsed, AUTH_TIMEOUT_MS)) {
            Serial.println(elapsed >= AUTH_TIMEOUT_MS
                ? "[ACAB] BLE authentication timed out; disconnecting"
                : "[ACAB] pairing window closed before authentication; disconnecting");
            if (gServer && gConnHandle != 0xffff) gServer->disconnect(gConnHandle);
        }
    }

    if (!gLinkConnected && gAdvIntended) {
        NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
        static uint32_t lastKick = 0;
        const uint32_t now = millis();
        if (adv && !adv->isAdvertising() && (uint32_t)(now - lastKick) >= 2000) {
            lastKick = now;
#if ACAB_BLE_PRIVACY
            // A HOST RESET (HCI timeout, controller fault) zeroes the random address, and the
            // re-sync only guarantees a PUBLIC one. Under BLE_OWN_ADDR_RANDOM every start() then
            // fails with BLE_HS_ENOADDR, and nothing re-establishes the RPA except the 900 s
            // rotation callout, so without this the board is invisible for up to 15 minutes while
            // this supervisor logs a restart every 2 s that cannot succeed. Reinstall privacy
            // first, and only then try to advertise.
            ble_addr_t rnd;
            if (ble_hs_id_copy_addr(BLE_ADDR_RANDOM, rnd.val, NULL) != 0) {
                Serial.println("[ACAB] random address gone (host reset?), reinstalling privacy");
                ble_hs_pvcy_rpa_config(ACAB_NIMBLE_ENABLE_RPA);
            }
#endif
            Serial.println("[ACAB] advertising had stopped, restarting (see advCompleteCb)");
            adv->start(0, advCompleteCb);
        }
    }

    if (!gDetChar || !gConnected) return;

    // Snapshot only enough state to choose this pass's stage. The snapshot is a capability, not
    // authority to publish: every queue below reacquires ReplayLock and validates the token at the
    // final prequeue boundary. A sync/disconnect in between therefore cancels this work cleanly.
    enum ReplayStage : uint8_t { REPLAY_INACTIVE, REPLAY_BEGIN, REPLAY_RECORD, REPLAY_END };
    ReplayStage stage = REPLAY_INACTIVE;
    uint64_t stageToken = 0;
    uint32_t stageSent = 0;
    {
        ReplayLock rl;
        if (!rl.locked || !gReplaySession.active()) return;
        stageToken = gReplaySession.token();
        if (gReplaySession.endPending()) {
            stage = REPLAY_END;
            stageSent = gReplaySession.sent();
        } else if (!gReplaySession.beginSent()) {
            stage = REPLAY_BEGIN;
        } else {
            stage = REPLAY_RECORD;
        }
    }

    // A rejected closing sentinel is retryable even though det_log has no record left and has
    // already dropped its draining flag. Queue and close it only if this is still the session that
    // produced stageSent; an old end can never close a replacement envelope.
    if (stage == REPLAY_END) {
        char endBuf[64];
        size_t endLen;
        { JsonPoolLock jp; JsonDocument doc(jp.alloc());
          doc["hist"] = "end";
          doc["n"]    = stageSent;
          endLen = serializeJson(doc, endBuf, sizeof(endBuf)); }
        if (endLen <= notifyCap()) {
            ReplayLock rl;
            if (!rl.locked || !gReplaySession.mayQueueEnd(stageToken)) return;
            if (queueDetNotify((const uint8_t*)endBuf, endLen))
                gReplaySession.noteEndQueued(stageToken);
        }
        return;
    }
    if (!detLogDraining()) {
        if (detLogDrainStartPending()) return;
        if (stage == REPLAY_RECORD) {
            // An accepted empty drain (or the tick after the last commit) still needs a closing
            // sentinel. Begin has already queued, so move directly to END without waiting for a
            // record-layer draining flag that is correctly false for zero rows.
            ReplayLock rl;
            if (rl.locked && gReplaySession.mayQueueRecord(stageToken))
                gReplaySession.noteEndPending(stageToken);
            return;
        }
        // REPLAY_BEGIN continues below so an accepted empty sync emits begin(n=0) before end.
    }
    // Wait for the MTU exchange before draining. At the 23-byte default gPeerMtu, notifyCap() is
    // 20 bytes - smaller than any replay frame (and the hist:begin lead-in). The peek/commit API
    // now prevents consumption at that size, but waiting still avoids a futile begin/retry loop
    // before the negotiated capacity is known.
    //
    // This waits for the exchange to HAPPEN. It does not wait for a big MTU, and the comment here
    // used to claim "the app always negotiates 512", which is false and was the premise behind
    // treating the over-cap branch below as unreachable: only Android asks (requestMtu(512)).
    // iOS never asks, and CoreBluetooth settles an iPhone near 185, i.e. notifyCap() == 182 - a
    // number smaller than most GPS-stamped replay frames. That is the link the HIST_TRIM ladder
    // and the gDrainOverCap counter below exist for.
    if (gPeerMtu <= 23) return;
    // Back-pressure: only push a replay frame while the mbuf pool has headroom, so we avoid an
    // enqueue rejection from a full pool. This also yields to live
    // notifies (which draw from the same pool), so a crowd just slows the drain instead of breaking
    // it. If we're low, skip this tick and let the pool drain (delay(20) in loop paces the retry).
    if (os_msys_num_free() < DRAIN_MBUF_MIN) return;

    char buf[512];
    DetLogReplay r;
    if (stage == REPLAY_BEGIN) {
        // Lead-in so the app can show a determinate "X of N". N is the exact pending count (not
        // status "buf", which is total ring occupancy). The {"hist":"end","n":N} sentinel closes it.
        // "from" is the resume point (first seq this drain will send): after a board-side wipe
        // reset the seq generation, the app rebases its persisted cursor to from-1 so the
        // end-of-drain checkpoint lands in the new generation instead of re-replaying forever.
        size_t len;
        { JsonPoolLock jp; JsonDocument doc(jp.alloc());
          doc["hist"] = "begin";
          doc["n"]    = detLogPendingDrain();
          doc["from"] = detLogDrainFrom();
          doc["gen"]  = detLogGeneration();
          len = serializeJson(doc, buf, sizeof(buf)); }
        if (len <= notifyCap()) {
            ReplayLock rl;
            if (!rl.locked || !gReplaySession.mayQueueBegin(stageToken) ||
                detLogDrainStartPending() ||
                (!detLogDraining() && detLogPendingDrain() != 0)) return;
            if (queueDetNotify((const uint8_t*)buf, len))
                gReplaySession.noteBeginQueued(stageToken);
        }
        return;
    }
    // Burst: up to DRAIN_BURST_MAX records per pass. Re-check the mbuf headroom before EVERY
    // notify - one 200-500B frame can consume several ~292B msys blocks, so a single up-front
    // check could still blast the pool - and re-check the connection/drain state each
    // iteration, since a disconnect callback on the NimBLE host task can land mid-burst.
    // NotifyLock stays per-record so live detections and OTA notifies interleave with the burst.
    for (int i = 0; i < DRAIN_BURST_MAX; i++) {
        // A sync can land between burst iterations. Re-snapshot the token AND require that its
        // begin has already been accepted; otherwise this pass must yield so the next one queues
        // the replacement begin before touching replacement records.
        uint64_t recordToken = 0;
        {
            ReplayLock rl;
            if (!rl.locked) return;
            recordToken = gReplaySession.token();
            if (!gReplaySession.mayQueueRecord(recordToken)) return;
        }
        if (!gConnected || !detLogDraining()) return;
        if (os_msys_num_free() < DRAIN_MBUF_MIN) return;
        if (detLogPeekForDrain(&r)) {
            // Peek leaves the durable cursor parked. Build down the HIST_TRIM ladder, queue the
            // fitting frame, and only then commit this exact seq. A size or host-queue failure
            // therefore leaves the record available to this or a later sync.
            uint8_t trim = HIST_TRIM_NONE;
            size_t len = serializeDetection(r.d, false, buf, sizeof(buf), true, r.seq, r.atUnix,
                                            r.whenMs, r.bootCount, ACAB_ELIDE_NONE, trim);
            while (len > notifyCap() && trim + 1 < HIST_TRIM_MAX) {
                trim++;
                // Skip a step that cannot shrink THIS record. Rebuilding a byte-identical frame
                // only to fail the same comparison is pure cost, and this is a per-record path -
                // a full drain is thousands of records. A skipped step still counts as reached,
                // which is correct: its output IS the frame we already hold.
                if ((trim == HIST_TRIM_ANCHOR && !r.atUnix)    ||
                    (trim == HIST_TRIM_NAME   && !r.d.name[0]) ||
                    (trim == HIST_TRIM_FIX    && !r.d.lat && !r.d.lon && !r.d.gpsAgeMs) ||
                    (trim == HIST_TRIM_ID     && !r.d.id[0])) continue;
                len = serializeDetection(r.d, false, buf, sizeof(buf), true, r.seq, r.atUnix,
                                         r.whenMs, r.bootCount, ACAB_ELIDE_NONE, trim);
                if (len == 0) break;
            }
            if (len > 0 && len <= notifyCap()) {     // never send truncated JSON
                bool queueRejected = false;
                bool committed = false;
                {
                    // The token check, NimBLE acceptance, record-layer commit, and end.n update
                    // are one generation transaction. startReplaySession/stopReplaySession take
                    // this same mutex, so none can splice itself into the middle.
                    ReplayLock rl;
                    if (!rl.locked || !gReplaySession.mayQueueRecord(recordToken)) return;
                    if (!queueDetNotify((const uint8_t*)buf, len)) {
                        queueRejected = true;
                    } else if (detLogCommitDrain(r.seq, r.drainGeneration)) {
                        committed = gReplaySession.noteRecordCommitted(recordToken);
                    }
                }
                if (queueRejected) {
                    static uint32_t sLastQueueWarn = 0;
                    if ((uint32_t)(millis() - sLastQueueWarn) > 5000) {
                        sLastQueueWarn = millis();
                        Serial.printf("[ACAB] replay seq %u notify queue rejected - retained for retry\n",
                                      (unsigned)r.seq);
                    }
                    return;
                }
                // A record-layer invalidation that does not start a replacement BLE session can
                // still reject commit. The notify is then a conservative duplicate, never a count
                // or cursor advance. Sync/disconnect cannot hit this branch: ReplayLock serialized
                // them across queue+commit above.
                if (!committed) return;
                if (trim != HIST_TRIM_NONE) gDrainTrimmed++;
            } else {
                // Unreachable for the supported iPhone-class 182 B payload: HIST_TRIM_ID makes the
                // widest minimal core 159 B, pinned by the host budget. A smaller peer or future
                // schema drift still cannot destroy the row: stop this drain WITHOUT committing,
                // close its envelope with a shortfall, and leave seq available for a later sync.
                gDrainOverCap++;
                static uint32_t sLastDrainWarn = 0;
                if (millis() - sLastDrainWarn > 5000) {
                    sLastDrainWarn = millis();
                    Serial.printf("[ACAB] replay seq %u is %uB over MTU cap %u fully trimmed - "
                                  "NOT consumed; drain stopped (%u attempts, peer MTU %u)\n",
                                  (unsigned)r.seq, (unsigned)len, (unsigned)notifyCap(),
                                  (unsigned)gDrainOverCap, (unsigned)gPeerMtu);
                }
                {
                    ReplayLock rl;
                    if (!rl.locked || !gReplaySession.mayQueueRecord(recordToken)) return;
                    detLogStopDrain();
                    gReplaySession.noteEndPending(recordToken);
                }
                return;
            }
        } else {
            // The record layer is complete; the BLE layer owns retrying the unacknowledged
            // envelope close if the host queue is momentarily full. A stale false result from an
            // invalidated peek cannot arm end on the replacement session.
            ReplayLock rl;
            if (rl.locked && gReplaySession.mayQueueRecord(recordToken))
                gReplaySession.noteEndPending(recordToken);
            return;
        }
    }
}

// OTA stall watchdog. Belt-and-suspenders to the disconnect handler: if a session sits
// idle (no otaBegin/otaWrite) longer than the timeout - a stalled uploader, a drop the
// callback missed - abort it and bring the radios back so OTA can't wedge BUSY forever.
void acabBleOtaWatchdog() {
    // A deferred finish (end arrived before the last chunk) whose grace window lapsed without the
    // straggler completing the image: fail it here off the host task, bring the radios back, and
    // report the size error the end handler deferred.
    if (otaPendingFinishExpired()) {
        otaQuiesce(false);
        otaNotify("{\"ota\":\"err\",\"e\":\"size\"}");
        return;
    }
    static const uint32_t kOtaStallMs = 30000;
    if (otaInProgress() && otaIdleMs() > kOtaStallMs) {
        otaAbort();
        otaQuiesce(false);
        otaNotify("{\"ota\":\"err\",\"e\":\"stall\"}");
    }
}

// Pack one detection into compact JSON and NOTIFY the connected app.
void acabBleNotifyDetection(const AcabDetection& d, bool isNew) {
    if (!gDetChar || !gConnected) return;

    // ONE builder for both paths. This function used to carry its OWN copy of the field assembly,
    // with a comment on serializeDetection asking whoever edited one to remember the other; that is
    // not a contract, it is a countdown. serializeDetection(hist=false) produces the identical
    // record, so the live path now calls it.
    char buf[512];
    size_t len = serializeDetection(d, isNew, buf, sizeof(buf), /*hist=*/false, 0, 0, 0, 0,
                                    ACAB_ELIDE_NONE);
    if (len == 0) return;

    // DEGRADE, DO NOT DROP. Over the peer's usable MTU budget (an iPhone negotiating 185 leaves
    // ~182 usable bytes, and a fully-populated drone Remote ID record exceeds that), give up the
    // optional enrichment one field at a time in the documented order until it fits, instead of
    // skipping the sighting. An elided field is LOST, not deferred: StoredDet persists none of
    // the elidable fields, so replay cannot restore them. The live notify's job is the alert,
    // not the archive, and the fields it depends on are never elidable. See detect_elide.h.
    uint8_t used = ACAB_ELIDE_NONE;
    while (len > notifyCap() && used < ACAB_ELIDE_MAX) {
        used++;
        len = serializeDetection(d, isNew, buf, sizeof(buf), /*hist=*/false, 0, 0, 0, 0, used);
        if (len == 0) return;
    }
    if (len > notifyCap()) {
        // Even the minimal record does not fit. Near-impossible now (it needs a long name/detail on
        // a 23-byte MTU), but if it ever happens it is a real gap in the live feed and must stay
        // visible rather than becoming silence. Counter is surfaced in the {"diag":true} reply.
        gNotifyOverCap++;
        static uint32_t sLastWarn = 0;
        if (millis() - sLastWarn > 5000) {
            sLastWarn = millis();
            Serial.printf("[ACAB] detection %uB over MTU cap %u even fully elided - skipped "
                          "(%u total, peer MTU %u)\n",
                          (unsigned)len, (unsigned)notifyCap(), (unsigned)gNotifyOverCap,
                          (unsigned)gPeerMtu);
        }
        return;
    }
    if (used != ACAB_ELIDE_NONE) {
        gNotifyElided++;
        static uint32_t sLastElideWarn = 0;
        if (millis() - sLastElideWarn > 5000) {
            sLastElideWarn = millis();
            Serial.printf("[ACAB] live notify elided through %s to fit MTU cap %u (%u total)\n",
                          acabElideKey((AcabElidableField)(used - 1)), (unsigned)notifyCap(),
                          (unsigned)gNotifyElided);
        }
    }
    { NotifyLock nl; gDetChar->setValue((uint8_t*)buf, len); gDetChar->notify(); }
}

void acabBleStartAdvertising() {
    if (gAdvIntended) return;                       // idempotent
    NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
    if (!adv) return;
    gAdvIntended = true;                            // set BEFORE start so the supervisor can help
    adv->start(0, advCompleteCb);
    Serial.println("[ACAB] advertising started (deferred until the power + pairing gates settled)");
}

void acabBlePairGateEnable() {
    // ENFORCEMENT ONLY. Leaves the window shut, which is the state a warm boot must land in:
    // strangers refused, owner reconnects. Splitting this out fixes a composition bug between two
    // individually-correct changes - enforcement used to be switched on ONLY inside the window
    // opener, and the opener was gated on a physical start, so every OTA restart, panic, watchdog
    // and brownout came back with enforcement OFF and admitted ANY phone indefinitely. That was
    // worse than either behaviour on its own.
    gPairGateEnabled = true;
}

void acabBleOpenPairingWindow() {
    gPairWindowUntil = millis() + ACAB_PAIR_WINDOW_MS;
    gPairWindowArmed = true;
    gPairWindowLatchedClosed = false;
    // Also enables the gate, so a target that only ever calls THIS still enforces correctly.
    gPairGateEnabled = true;
    Serial.printf("[pair] window OPEN for %lus - a new phone may bond now\n",
                  (unsigned long)(ACAB_PAIR_WINDOW_MS / 1000));
}
bool acabBlePairWindowOpen() {
    const bool open = acabPairWindowOpenAt(millis(), gPairWindowUntil, gPairWindowArmed,
                                           gPairWindowLatchedClosed);
    // Trip the latch the first time we observe closure. Called from every connect and every ~5 s
    // status build, so this happens within seconds of expiry, long before the comparison could go
    // wrong. Deliberately NOT persisted: RAM-only, because a power cycle is the reopen mechanism.
    if (!open && gPairWindowArmed) gPairWindowLatchedClosed = true;
    return open;
}
uint32_t acabBlePairWindowRemainingMs() {
    return acabPairWindowRemainingAt(millis(), gPairWindowUntil, gPairWindowArmed,
                                     gPairWindowLatchedClosed);
}

int acabBleBondCount() { return NimBLEDevice::getNumBonds(); }

uint32_t acabBleNotifyElidedCount()  { return gNotifyElided; }
uint32_t acabBleNotifyOverCapCount() { return gNotifyOverCap; }

void acabBleSetBatteryPct(int pct) { gBatteryPct = pct; }
void acabBleSetCharging(bool charging) { gCharging = charging; }

// ONE-SHOT expanded diagnostic, NOTIFIED (never stored) on the STATUS characteristic.
//
// Why Status and not a reply on Config: the GATT contract (see this file's header) is Detections
// NOTIFY, Config WRITE, Status READ|NOTIFY, OTA WRITE_NR|NOTIFY. Config is write-only - there is
// no command-response characteristic to answer on - so a request/response pair has to land on
// Status, which is the same transport the OTA acks already use. Triggered by {"diag":true}.
//
// Kept OUT of the periodic status on purpose: that JSON is already close to the ATT budget on a
// small-MTU peer, and everything here is only interesting when someone is actually looking.
void acabBleSendDiag() {
    if (!gStatChar) return;
    char buf[STATUS_JSON_MAX + 1];   // +1 makes truncation detectable; see STATUS_JSON_MAX
    size_t len;
    {
    JsonPoolLock jp;
    JsonDocument doc(jp.alloc());
    doc["diag"]   = true;                                  // marks this as the one-shot, not periodic
    // Radio ingest counters, moved HERE from the periodic status (2026-08-26): neither app parses
    // them, and the receipts contract (docs/ble-protocol.md, "Radio health cannot validate every
    // receipt") consumes them as DELTAS between a start diagnostic and an end diagnostic - this
    // reply - never off periodic frames. Moving them bought the periodic document 38 of the 70
    // declared bytes its worst case shed that day to fit back under STATUS_JSON_MAX (the rest:
    // sdrop's slot, and the fw + nrfv bounds). Full uint32, deliberately unclamped: a saturating
    // emit would freeze the delta and read as a dead radio.
    doc["wseen"]  = acabScannerWifiSeen();                 // 802.11 mgmt frames seen (see the doc's mgmt-gate caveat)
    doc["bseen"]  = acabScannerBleSeen();                  // BLE adverts ingested (= the nRF's forwards in dual mode)
    doc["sdrop"]  = acabScannerSinkDropTotal();
    doc["sdDeliv"]= acabScannerSinkDropDeliverOnly();      // benign: a missed live notify re-arrives
    doc["sdBuf"]  = acabScannerSinkDropBuffered();         // THE ONE THAT COSTS EVIDENCE
    doc["sdRepl"] = acabScannerSinkDropReplay();           // lost from one dump attempt, ring intact
    doc["sqHigh"] = acabScannerSinkHighWater();            // deepest the queue has been, of 32
    doc["nElide"] = acabBleNotifyElidedCount();            // live notifies that fit only after trimming
    doc["nOver"]  = acabBleNotifyOverCapCount();           // live notifies lost even fully trimmed
    doc["hTrim"]  = gDrainTrimmed.load();                  // replay frames that fit only after trimming
    doc["hOver"]  = gDrainOverCap.load();                  // fully trimmed replay attempts blocked by cap
    if (uint32_t faults = detLogFaults()) doc["buferr"] = faults;
    doc["up"]     = (uint32_t)(millis() / 1000);
    // Retained core dump, if any. Metadata ONLY - the 64 KB image itself is not shipped over this
    // path (see coredump_report.h; a raw dump over unacked notifies is not acceptable and its
    // export is a separate, explicitly-consented flow). cdElf is the app ELF SHA, which is the
    // dump's only identity: it does NOT imply the running firmware version, because a dump
    // survives an OTA.
    {
        const AcabCoredumpInfo& cd = acabCoredumpInfo();
        if (cd.present) {
            doc["cd"]     = true;
            doc["cdTask"] = cd.task;
            doc["cdPc"]   = cd.pc;
            doc["cdSize"] = cd.sizeBytes;
            doc["cdElf"]  = cd.elfSha;
        } else if (cd.corrupt) {
            doc["cd"]     = false;          // unreadable/invalid and still erase-required
            doc["cdSize"] = cd.sizeBytes;
        }
    }
    len = serializeJson(doc, buf, sizeof(buf));
    }
    // NOTIFY-ONLY, never setValue. This document is a DIFFERENT SHAPE from the periodic status,
    // and it rides the same characteristic because Config is write-only and there is nowhere else
    // to answer (see the note above). setValue-ing it left that shape sitting in the Status READ
    // value until the next periodic build up to 5 s later - and both apps poll Status with a READ
    // every 5 s as their small-MTU fallback, decoding whatever comes back through an all-defaults
    // status parser and immediately reconciling it. A poll landing in that window would have read
    // buzzer:false, desert:false, ign:0, wat:0 off a frame that simply does not carry those keys:
    // un-muting the board mid-Desert and re-pushing list state the user never touched. The
    // notify(value,len) overload sends this payload without touching the stored value, so the
    // READ path keeps returning the real status no matter what.
    //
    // The remaining half is on the CLIENT and firmware cannot close it: any app that adds a
    // diagnostics button must early-out on obj["diag"] == true BEFORE its DeviceStatus decode, or
    // the notify lands in the same reconciler. Nothing ships that button today - no client under
    // ios/, android/ or web/ writes {"diag":true} - so this reply is bench-only for now.
    // Overflow first, so an oversized reply is reported as what it is. Without this the frame
    // simply failed the notifyCap() test below and the operator was told it was an MTU miss.
    if (len >= STATUS_JSON_MAX) {
        statusJsonOverflowWarn("diag");
    } else if (len > 0 && gConnected && len <= notifyCap()) {
        NotifyLock nl;
        gStatChar->notify((uint8_t*)buf, len);
    }
    // Serial UNCONDITIONALLY, while the notify above is gated on the document fitting notifyCap().
    // The counters-only document normally sits well under an iPhone's 182-byte cap; a buferr fault
    // code, a retained core dump's cd* block, or counters that have run wide push it over, and in
    // that case these two lines are the only delivery there is.
    // Note what this does NOT buy: both lines live inside acabBleSendDiag, and the only thing that
    // calls it is the {"diag":true} config write, so reading them still needs a BLE writer (nRF
    // Connect, a script) to trigger the request. The USB console parses only "nrfdfu"
    // (beacon-board/main.cpp) and its periodic [diag] heartbeat carries none of these counters, so
    // there is no no-central path to them. If one is ever wanted, it needs a console command or a
    // place in that heartbeat; the Serial call here does not give it.
    Serial.printf("[diag] sink drops: total=%u deliver-only=%u buffered=%u replay=%u  qhigh=%u/%u\n",
                  (unsigned)acabScannerSinkDropTotal(), (unsigned)acabScannerSinkDropDeliverOnly(),
                  (unsigned)acabScannerSinkDropBuffered(), (unsigned)acabScannerSinkDropReplay(),
                  (unsigned)acabScannerSinkHighWater(), 32u);
    Serial.printf("[diag] mtu fit: live elided=%u live lost=%u | replay trimmed=%u replay blocked=%u"
                  "  (peer MTU %u, cap %u)\n",
                  (unsigned)acabBleNotifyElidedCount(), (unsigned)acabBleNotifyOverCapCount(),
                  (unsigned)gDrainTrimmed.load(), (unsigned)gDrainOverCap.load(),
                  (unsigned)gPeerMtu, (unsigned)notifyCap());
}

// Rebuild the status JSON and update the characteristic (notify if connected).
void acabBleUpdateStatus() {
    if (!gStatChar) return;
    char buf[STATUS_JSON_MAX + 1];   // +1 makes truncation detectable; see STATUS_JSON_MAX
    size_t len;
    {
    JsonPoolLock jp;
    JsonDocument doc(jp.alloc());
    // fwbuf's size IS the declared "fw" width in the host-test budget (test_acab_ble_service.cpp),
    // so the two must move together. 33 holds every real emission with zero truncation: the
    // longest label is mesh-detect's, bounded by its fwLabel[24] to 23 chars (the compile-time
    // labels are 11/12/18 chars, and ACAB_FW_LABEL is static_asserted <= 23 at its use in
    // beacon-board/main.cpp), plus one space, plus the version, asserted below - 23 + 1 + 8 = 32.
    // Truncation would not just look wrong: both apps parse the VERSION off the end of this string
    // (DeviceStatus.version), so the tail is the load-bearing half.
    static_assert(sizeof(ACAB_FW_VERSION) <= 9,
                  "ACAB_FW_VERSION grew past 8 chars: fwbuf and the host-test fw width assume "
                  "label(<=23) + ' ' + version(<=8) fits 32 chars - re-size both together");
    char fwbuf[33];
    snprintf(fwbuf, sizeof(fwbuf), "%s %s", gFwLabel, ACAB_FW_VERSION);
    doc["fw"]     = fwbuf;
    doc["proto"]  = ACAB_BLE_PROTO_VERSION;   // BLE JSON contract version; absent = 0 = compatible
    // Seconds left in the new-phone pairing window, emitted ONLY while it is open (absent = closed,
    // which is the normal steady state and costs no MTU). Lets the app show a countdown during
    // setup instead of the user guessing how long they have.
    if (uint32_t rem = acabBlePairWindowRemainingMs()) doc["pairw"] = rem / 1000;
    doc["up"]     = (uint32_t)(millis() / 1000);
    doc["total"]  = acabScannerTotalDetections();
    doc["ble"]    = acabScannerBLEEnabled();
    doc["wifi"]   = acabScannerWiFiEnabled();
    doc["wifiEco"]= acabScannerWifiEco();   // 0/3/7/15 s WiFi-sweep sleep; apps show the eco picker

    doc["axon"]   = axonIsEnabled();   // body-cam toggle state; both apps read "bodycam" first and fall back to this
    doc["moto"]   = policeIsEnabled(); // broad Motorola-OUI sub-toggle; apps treat an absent key as true (pre-split firmware)
    doc["tracker"]= trackerIsEnabled();
    doc["glasses"]= glassesIsEnabled();
    doc["flock"]  = flockIsEnabled();  // Flock/ALPR toggle state; apps treat an absent key as true
    doc["drone"]  = droneIsEnabled();  // drone Remote ID toggle state; absent key = true
    doc["droui"]  = droneOuiIsEnabled();  // drone vendor-OUI fallback opt-in state; absent key = false (default off)
    doc["ncam"]   = netcamIsEnabled();  // network-camera opt-in state; absent key = false (default off)
    doc["buzzer"] = alertsBuzzerEnabled();
    doc["vol"]    = alertsVolume();
    if (!alertsLedEnabled()) doc["ledon"] = false;   // only when off; absent = on (default), saves MTU bytes
    doc["gps"]    = acabBleGetPhoneGps(nullptr, nullptr, 60000);
    doc["buf"]    = detLogCount();          // stored offline records
    doc["bufon"]  = detLogEnabled();        // buffering opt-in state
    // Session-only ownership conflict. Absent means false. A second bonded phone's different key
    // cannot silently destroy the first phone's nonempty history; the app must ask for an explicit
    // clear/ownership transfer, then re-send its key. Reset/rebuilt at every authentication.
    if (gSessionKeyMismatch) doc["keymis"] = true;
    // Only sent when ON. Absent means off, which is the default, so the common case costs no MTU
    // bytes - same trick as "ledon" above. The app needs it to reconcile the switch AND to keep
    // showing the weakened-auto-wipe warning for as long as the mode is actually armed.
    if (detLogBufferAll()) doc["bufall"] = true;
    // Stationary capture reached ring capacity, so later nearby rows may have been omitted. This is
    // a capacity/censoring-risk flag, not proof of an actual refusal (`bufdrops` is that counter).
    // Sent only when true and shown beside the log rather than as a settings detail.
    if (detLogSaturated()) doc["bufsat"] = true;
    // Latched flash fault bitmask. A nonzero value means the ring stopped accepting writes rather
    // than pretending evidence was stored; only a fully successful physical wipe clears it.
    if (uint32_t faults = detLogFaults()) doc["buferr"] = faults;
    if (detLogWipePending()) doc["wiping"] = true;   // deferred buffer erase still sweeping; absent = idle
    doc["desert"] = desertIsEnabled();      // Desert mode (report every device in range)
    doc["ign"]    = acabScannerIgnoreCount();  // ignore-list size, for app reconciliation
    doc["wat"]    = acabScannerWatchCount();    // watchlist size, for app reconciliation
    // wseen / bseen / sdrop left this document on 2026-08-26 and now ride ONLY the {"diag":true}
    // reply (plus the [diag] serial heartbeat). Verified before the move: neither shipped app
    // parses any of the three, and the receipts contract in docs/ble-protocol.md reads them as
    // start/end DIAGNOSTIC deltas, not off periodic frames. Their three full-uint32 slots are
    // what the worst-case status document shed to fit back under STATUS_JSON_MAX - re-adding any
    // of them here fails the host-test budget's hard ceiling, so if one is ever wanted back it
    // has to buy its bytes from some other key first.
    if (acabScannerHasCoProc()) doc["nbb"] = acabScannerCoProcBbCount();  // nRF black-box record count
    if (gBatteryPct >= 0)       doc["bat"] = gBatteryPct;                 // battery %, sense-divider boards only
#ifdef ACAB_DUAL_RADIO
    // Co-processor (nRF) liveness for the app's "bluetooth detection offline" warning. Always
    // emitted on the dual board: the app only warns when it is present AND false, so an absent
    // key (older firmware / single-radio) never trips it. See the cross-target contract.
    doc["co"]  = acabScannerCoProcAlive();
    // Companion nRF app version, for the app's "nRF update available" check (BLE DFU). Emit only
    // once heard (>=0) so single-radio builds and a not-yet-announced nRF never send a stray -1.
    // Capped at 9999 (4 digits): the value originates as atoi of an UNTRUSTED UART line, and the
    // real domain is a small monotonic int (currently 2). parseAdvLine (beacon-board main.cpp)
    // already clamps what it stores; this re-cap makes the host-test budget's 4-digit "nrfv"
    // width provable from THIS file alone, whatever a future board's acabNrfVersion returns.
    { int nrfv = acabNrfVersion(); if (nrfv > 9999) nrfv = 9999; if (nrfv >= 0) doc["nrfv"] = nrfv; }
    // Carrier revision so the app (and support) can see which board is in the case without opening
    // it: "A" = the first 250 (slide switch), "B" = button power + VBUS sense. Auto-detected.
    doc["rev"] = acabBoardIsRevB() ? "B" : "A";   // was `if (acabBoardIsRevB)`: a function-ADDRESS
                                                  // truthiness test, never false, so the guard did
                                                  // nothing. The emit is unconditional by design.
    // "nRF is updating over BLE DFU" - emit only while true. The app uses it to show "updating
    // co-processor" instead of the co-proc fault banner during the window the nRF is in DFU.
    if (acabNrfDfuActive()) doc["nrfup"] = true;
    // Battery charging: emit only when true (absent = draining/unknown = normal battery UI), to
    // keep this JSON compact under the ATT budget.
    if (gCharging) doc["chg"] = true;
#endif
    // The nRF's detailed view (adv/fwd/scan) rides the [diag] serial line, not the status
    // notify, to keep this JSON safely under the BLE ATT MTU.

    len = serializeJson(doc, buf, sizeof(buf));
    }   // release the JSON pool before touching the BLE stack below
    // OVERFLOW: keep the last COMPLETE frame rather than publishing a truncated one. This is the
    // one case where a stale READ value beats a fresh one - serializeJson cut the document
    // mid-token, both apps drop unparseable JSON silently, and a frame this size can never notify
    // (STATUS_JSON_MAX > NOTIFY_MAX), so storing it would leave the apps with no status at all
    // instead of a slightly old one. Since 2026-08-26 the DECLARED worst case fits under
    // STATUS_JSON_MAX (the host-test budget holds it there as a hard ceiling), so this guard is
    // defense in depth against a width that budget missed, not an expected path - which is
    // exactly why the console line below must stay: a hit now means the budget is wrong.
    const bool overflowed = (len >= STATUS_JSON_MAX);
    if (overflowed) statusJsonOverflowWarn("status");
    // Every COMPLETE frame is stored, before the notify guard and regardless of MTU: the status is
    // READable, and the apps poll it (~every 5 s) as a fallback, so a READ must always return the
    // freshest WHOLE status even when the notify below is skipped for a small negotiated MTU.
    // Overflow is the only thing that skips the store, and it does so to keep the previous whole
    // frame - see above.
    // Notify only a connected peer (no client = nothing to notify, and no misleading "skipped" spam on a
    // USB-only bench). A fuller status must never ride out truncated past the peer's negotiated MTU, which
    // would hand the app invalid JSON; skip only the notify then - the READ value set above stays fresh and
    // the apps' ~5 s status poll covers it. The setValue+notify pair is serialized against the other
    // characteristic writers (see NotifyLock).
    if (len > 0 && !overflowed) {
        NotifyLock nl;
        gStatChar->setValue((uint8_t*)buf, len);
        if (gConnected && len <= notifyCap()) gStatChar->notify();
    }
    if (gConnected && len > 0 && !overflowed && len > notifyCap()) {
        // RATE-LIMITED, same 5 s gate as the live-notify warnings above. On a small-MTU peer this
        // branch is the STEADY STATE, not an exception: a full status document on a dual-radio
        // board is comfortably past an iPhone's 182-byte cap, so ungated it printed once per
        // status BUILD, and every build a config write drove added another line on top of the
        // periodic one, burying the [diag] line, the pairing-window lines and the genuinely rare
        // detection warnings a bench operator is watching the console for.
        //
        // BE CLEAR ABOUT WHAT THIS GATE BUYS, because the window is the same number as the
        // cadence: beacon-board's periodic caller fires on now - lastStatus > 5000 (main.cpp), so
        // consecutive periodic builds are already more than 5 s apart and every one of them still
        // clears this gate - about twelve lines a minute on an iPhone link, unchanged. What
        // collapses is only the EXTRA builds landing inside the same 5 s window as a periodic one,
        // and the statusDirty gate in CfgCb has already removed most of those. Actually thinning
        // the periodic line needs a much longer window (30-60 s) or a log-once-per-connection off
        // the MTU-change callback; neither is done here, so do not read this as taming it.
        // The READ value is still fresh and both apps poll it every 5 s (iOS statusPollInterval,
        // Android STATUS_POLL_MS), so a skipped notify here is not a fault to shout about.
        static uint32_t sLastStatusWarn = 0;
        if (millis() - sLastStatusWarn > 5000) {
            sLastStatusWarn = millis();
            Serial.printf("[ACAB] status JSON %u B over MTU cap %u - notify skipped, READ stays "
                          "fresh (peer MTU %u)\n",
                          (unsigned)len, (unsigned)notifyCap(), (unsigned)gPeerMtu);
        }
    }
}

bool acabBleClientConnected() { return gConnected || gOwnerCaptureBlocked; }

// Latest phone GPS the app pushed, if it arrived within maxAgeMs. Returns false
// (leaving lat/lon untouched) when there's no fresh fix.
bool acabBleGetPhoneGps(double* lat, double* lon, uint32_t maxAgeMs, uint32_t* ageMs) {
    portENTER_CRITICAL(&gGpsMux);
    const bool valid = gPhoneGpsValid;
    const uint64_t fixUs = gPhoneGpsUs;
    const double la = gPhoneLat, lo = gPhoneLon;
    portEXIT_CRITICAL(&gGpsMux);
    if (!valid) return false;
    uint32_t age = 0;
    if (!acabGpsAgeMs((uint64_t)esp_timer_get_time(), fixUs, maxAgeMs, &age)) return false;
    if (lat)   *lat   = la;
    if (lon)   *lon   = lo;
    if (ageMs) *ageMs = age;
    return true;
}

// OFFLINE BUFFER ONLY. The last fix the app pushed this boot, surviving disconnect only for a
// session whose key was accepted for the current ring generation. Same age contract: false,
// outputs untouched, when there is no fix or it is older than maxAgeMs.
//
// WHY THIS IS NOT THE SAME FUNCTION AS acabBleGetPhoneGps: the fix is erased on disconnect so no
// outward-facing path can attach the owner's position to traffic seen after they left, and
// mesh-detect's transmission boundary depends on exactly that. But detLogAppend refuses to write
// while the app is connected, so the offline buffer only ever runs inside that erased window and
// every buffered record was being stored with lat = lon = 0 - the whole point of a deploy-and-leave
// capture, silently absent. Two readers with two different rules, so two functions.
//
// THE RULE FOR ANY NEW CALLER: this is the only fix a board can offer while its owner is away, so
// it may be written into the AES-CTR encrypted ring and nothing else. Do not notify it, do not
// send it over the mesh, do not put it in the status document. If a second caller ever appears,
// re-derive the leak argument in ServerCb::onDisconnect from scratch.
//
// HOW THE ONE CALLER OBEYS THAT, and why a guard on the notify would not have been enough. The
// stamp in handleDetection does NOT set d.lat/d.lon from this: it fills a DetLogGpsStamp that
// rides beside the record on the sink queue, and only detLogAppend reads it. Setting it on the
// detection would have been a transmissible shape - the SAME AcabDetection is both buffered and
// delivered, the buffer-bearing item deliberately holds under ~10 ms of backpressure while the
// sink is mid flash-erase, and a phone connecting inside that window makes detLogAppend refuse the
// row (it only accepts while the app is away) while the sink still notifies it. The coordinate
// could otherwise have gone to a later phone. The queue's owner-admission epoch now independently
// drops the whole stale delivery at its final sink boundary; keeping the retained fix out of the
// live detection remains structural defense in depth.
//
// WHAT DOES STILL LEAVE THE BOARD: the stored record itself, on replay, once the current session
// supplies the exact accepted generation key. A different-key phone gets keymis and no replay.
// That authorized replay is the buffer's purpose (docs/ble-protocol.md, "Offline detection
// buffer"); the boundary above is about everything that is NOT that replay.
bool acabBleGetLastPhoneGps(double* lat, double* lon, uint32_t maxAgeMs, uint32_t* ageMs) {
    portENTER_CRITICAL(&gGpsMux);
    const bool valid = gLastPhoneGpsValid;
    const uint64_t fixUs = gLastPhoneGpsUs;
    const double la = gLastPhoneLat, lo = gLastPhoneLon;
    portEXIT_CRITICAL(&gGpsMux);
    if (!valid) return false;
    uint32_t age = 0;
    // Unlike uint32 millis subtraction, this stays stale after one or many 49.7-day wraps. The
    // retained owner position therefore cannot re-enter the encrypted ring after its consented
    // age window has passed, even on a continuously powered stationary deployment.
    if (!acabGpsAgeMs((uint64_t)esp_timer_get_time(), fixUs, maxAgeMs, &age)) return false;
    if (lat)   *lat   = la;
    if (lon)   *lon   = lo;
    if (ageMs) *ageMs = age;
    return true;
}
