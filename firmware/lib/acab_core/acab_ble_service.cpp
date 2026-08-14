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
#include "pair_window.h"    // rollover-safe window comparison (host-tested)
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

// {"nrfdfu":true} request latch. Set on the NimBLE host task, drained from loop() so the S3
// forwards the DFU trigger off the host task (see acabBleTakeNrfDfuRequest). An atomic exchange
// makes the read-and-clear indivisible: a request that arrives while loop() drains the latch is
// either consumed by that exchange or remains set for the next pass.
static std::atomic<bool> gNrfDfuReq{false};
static bool nrfDfuMayArmNow();
bool acabBleTakeNrfDfuRequest() {
    const bool requested = gNrfDfuReq.exchange(false, std::memory_order_acq_rel);
    if (!requested) return false;
    const bool allowed = nrfDfuMayArmNow();
    if (!allowed) {
        Serial.println("[nrf] DFU request expired or link is not secure; power-cycle and retry");
    }
    return allowed;
}

// {"poweroff":true} request latch. SAME host-task-set / loop()-drained discipline as gNrfDfuReq
// above, because powerOffDeepSleep blocks on the nRF park handshake and then never returns - it
// cannot run on the NimBLE host task. Unlike DFU there is NO physical-pairing-window gate: powering
// off a board is low-risk (the user just presses the button to bring it back), and WRITE_ENC already
// means only a bonded peer reaches the write. The rev-B check and the mid-OTA guard live at the loop
// drain, not here.
static std::atomic<bool> gPowerOffReq{false};
bool acabBleTakePowerOffRequest() {
    return gPowerOffReq.exchange(false, std::memory_order_acq_rel);
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

// Latest phone GPS the app pushed over the config characteristic (0 = none yet).
static volatile double   gPhoneLat = 0, gPhoneLon = 0;
static volatile uint32_t gPhoneGpsMs = 0;
// gPhoneLat/Lon are 64-bit: reads/writes aren't atomic on the 32-bit Xtensa core and they
// cross tasks (BLE host writes them, the scanner task reads them), so a snapshot can tear
// (new high word + old low word). Guard the pair with a short spinlock.
static portMUX_TYPE      gGpsMux = portMUX_INITIALIZER_UNLOCKED;

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
static uint32_t              gHistSent  = 0;     // records sent so far in the current replay drain
static bool                  gHistBeginSent = false;  // whether this drain's {"hist":"begin","n":N} lead-in went out
// Replay back-pressure. notify() is void in NimBLE 1.4.x (can't report a drop), so we pace the
// drain by the mbuf pool instead: only push a frame while os_msys_num_free() has headroom.
// Blasting into a full pool silently loses records -> seq gaps -> the app re-syncs and the drain
// never converges in a crowd. Gating on free mbufs paces us to the link's real capacity AND makes
// the drain yield to the live-notify traffic that draws from the same pool.
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
static bool gOtaPaused    = false;
static bool gOtaSavedBle  = true;
static bool gOtaSavedWifi = true;

static bool otaQuiesce(bool pause) {
    if (pause) {
        if (gOtaPaused) return false;                // already quiesced: don't clobber the saved state
        gOtaSavedBle  = acabScannerBLEEnabled();
        gOtaSavedWifi = acabScannerWiFiEnabled();
        gOtaPaused    = true;
        acabScannerSetWiFi(false);
        acabScannerSetBLE(false);                    // also stops the nRF's scan ("S0") on the dual board
    } else {
        if (!gOtaPaused) return false;               // nothing to restore
        gOtaPaused = false;
        acabScannerSetWiFi(gOtaSavedWifi);
        acabScannerSetBLE(gOtaSavedBle);
    }
    return true;
}

// Cap on the JSON we put in one notify. Raised past the old 244 (247-MTU) limit because the
// status frame grew (every detector toggle + the diagnostics) past it: we now negotiate a 512
// MTU (setMTU below + the apps' requestMtu) and cap at 500, which fits the 512-byte scratch
// buffers and the 509-byte wire limit of MTU 512 (and the 512-byte attribute cap) with margin,
// carrying the status and a fully-populated drone/history record. A record over the cap is
// skipped (the app sees a seq gap and re-syncs) rather than sent truncated and unparseable.
static const size_t          NOTIFY_MAX = 500;

// Live negotiated ATT MTU with the connected peer. Starts at the BLE default 23 and is updated
// on the MTU-exchange callback (ServerCb::onMTUChange); reset to 23 on each new connect. Every
// notify path caps its frame at notifyCap() below, so a peer that negotiates a small MTU (e.g.
// iPhone 185) gets frames sized to what it can actually receive instead of a silently dropped
// notify. The status READ path stays fresh regardless (setValue is unconditional there).
static volatile uint16_t     gPeerMtu = 23;

// Per-notify size cap: the smaller of NOTIFY_MAX and the peer's usable payload (MTU - 3 bytes of
// ATT notify header). gPeerMtu is always >= 23 so (gPeerMtu - 3) >= 20.
static size_t notifyCap() {
    size_t mtuCap = (gPeerMtu > 3) ? (size_t)(gPeerMtu - 3) : 0;
    return (mtuCap < NOTIFY_MAX) ? mtuCap : NOTIFY_MAX;
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
        gConnected = true;
        Serial.println("[ACAB] BLE peer secure and ready");
    }
    // Track the negotiated MTU so every notify path can size to what the peer accepts (see
    // notifyCap). Fires after connect once the client exchanges MTU.
    void onMTUChange(uint16_t mtu, ble_gap_conn_desc*) override {
        gPeerMtu = mtu;
        Serial.printf("[ACAB] MTU negotiated: %u\n", (unsigned)mtu);
    }
    void onDisconnect(NimBLEServer*) override {
        gLinkConnected = false;
        gConnected = false;
        gConnHandle = 0xffff;
        gAuthStartedMs = 0;
        gPeerKnownAtConnect = false;
        gBoardHadBondAtConnect = false;
        // A phone fix belongs to one authenticated connection. Keeping it after the
        // owner leaves lets later scanner rows, and especially the public mesh target,
        // inherit a precise observer location that is no longer current or consented.
        portENTER_CRITICAL(&gGpsMux);
        gPhoneLat = 0; gPhoneLon = 0; gPhoneGpsMs = 0;
        portEXIT_CRITICAL(&gGpsMux);
        gIgnoreStageN = 0; gWatchStageN = 0;   // drop any half-staged chunk sequence on link drop
        gIgnoreHadContent = false; gWatchHadContent = false;
        // A link drop mid-update must not leave OTA stuck BUSY with the radios paused:
        // abort the session and un-quiesce so the next connect can start fresh.
        if (otaInProgress()) { otaAbort(); otaQuiesce(false); }
        // Abort any in-flight replay drain. gDraining/gHistBeginSent survive a link drop, so a
        // reconnect that races ahead of the app's re-arming {sync} would resume streaming hist
        // frames from the stale cursor with NO fresh {"hist":"begin"} lead-in (orphan records
        // outside any begin/end envelope). Force the next drain to wait for a {sync}.
        detLogStopDrain(); gHistBeginSent = false;
        acabScannerReArmCapture();                 // app left: re-arm offline capture
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
        std::string v = c->getValue();
        if (v.empty()) return;
        JsonDocument doc;
        if (deserializeJson(doc, v) != DeserializationError::Ok) return;

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
        }
        // Broad Motorola Solutions OUI match: sub-toggle of the body-cam category.
        // Lets a user quiet the noisy corporate-OUI proxy while keeping the conf-90
        // Axon BWCDEVICE tag and Utility BodyWorn running.
        if (doc["motorola"].is<bool>()) {
            bool on = doc["motorola"].as<bool>();
            policeSetEnabled(on);
            Serial.printf("[ACAB] Motorola broad-OUI match %s\n", on ? "on" : "off");
        }
        if (doc["tracker"].is<bool>()) {
            bool on = doc["tracker"].as<bool>();
            trackerSetEnabled(on);
            Serial.printf("[ACAB] Tracker detector %s\n", on ? "on" : "off");
        }
        if (doc["glasses"].is<bool>()) {      // recording-glasses detector (BLE mfg company ID)
            bool on = doc["glasses"].as<bool>();
            glassesSetEnabled(on);
            Serial.printf("[ACAB] Glasses detector %s\n", on ? "on" : "off");
        }
        if (doc["flock"].is<bool>()) {        // Flock/ALPR detector (BLE + WiFi)
            bool on = doc["flock"].as<bool>();
            flockSetEnabled(on);
            Serial.printf("[ACAB] Flock/ALPR detector %s\n", on ? "on" : "off");
        }
        if (doc["drone"].is<bool>()) {        // drone Remote ID detector (BLE + WiFi)
            bool on = doc["drone"].as<bool>();
            droneSetEnabled(on);
            Serial.printf("[ACAB] Drone detector %s\n", on ? "on" : "off");
        }
        if (doc["droneoui"].is<bool>()) {     // drone vendor-OUI fallback opt-in (default OFF; may false-positive on stationary drone-vendor gear)
            bool on = doc["droneoui"].as<bool>();
            droneOuiSetEnabled(on);
            Serial.printf("[ACAB] Drone OUI fallback %s\n", on ? "on" : "off");
        }
        if (doc["netcam"].is<bool>()) {       // network-camera opt-in (default OFF; widens WiFi to data frames, see netcam_detect.cpp)
            bool on = doc["netcam"].as<bool>();
            netcamSetEnabled(on);
            Serial.printf("[ACAB] Network-camera detector %s\n", on ? "on" : "off");
        }
        if (doc["desert"].is<bool>()) {       // Desert mode: report EVERY device in range
            bool on = doc["desert"].as<bool>();
            desertSetEnabled(on);
            Serial.printf("[ACAB] Desert mode %s\n", on ? "ENABLED" : "disabled");
        }
        if (doc["buzzer"].is<bool>()) {
            bool on = doc["buzzer"].as<bool>();
            alertsSetBuzzerEnabled(on);
            Serial.printf("[ACAB] Buzzer %s\n", on ? "on" : "off");
        }
        if (doc["led"].is<bool>()) {
            bool on = doc["led"].as<bool>();
            alertsSetLedEnabled(on);
            Serial.printf("[ACAB] LED %s\n", on ? "on" : "off (lights out)");
        }
        if (doc["volume"].is<int>()) {
            int v = doc["volume"].as<int>();
            if (v < 0) v = 0;
            if (v > 100) v = 100;
            alertsSetVolume((uint8_t)v);
            Serial.printf("[ACAB] Volume %d\n", v);
        }
        if (doc["ble"].is<bool>()) {
            bool on = doc["ble"].as<bool>();
            acabScannerSetBLE(on);
            Serial.printf("[ACAB] BLE scan %s\n", on ? "on" : "off");
        }
        if (doc["wifi"].is<bool>()) {
            bool on = doc["wifi"].as<bool>();
            acabScannerSetWiFi(on);
            Serial.printf("[ACAB] WiFi scan %s\n", on ? "on" : "off");
        }
        if (doc["wifiEco"].is<int>()) {   // 0/3/7/15 s of WiFi RX sleep between sweeps (battery SKU)
            int sec = doc["wifiEco"].as<int>();
            acabScannerSetWifiEco(sec);
            Serial.printf("[ACAB] WiFi eco = %ds\n", acabScannerWifiEco());
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
            }
        }
        // Phone GPS from the app: where we are, stamped onto detections + the mesh line.
        if (doc["lat"].is<float>() && doc["lon"].is<float>()) {
            double la = doc["lat"].as<double>(), lo = doc["lon"].as<double>();
            if (la >= -90.0 && la <= 90.0 && lo >= -180.0 && lo <= 180.0) {
                uint32_t now = millis();
                portENTER_CRITICAL(&gGpsMux);
                gPhoneLat = la; gPhoneLon = lo; gPhoneGpsMs = now;
                portEXIT_CRITICAL(&gGpsMux);
            }
        }
        // --- offline detection buffer (det_log) ---
        if (doc["buffer"].is<bool>()) {
            bool on = doc["buffer"].as<bool>();
            detLogSetEnabled(on);
            Serial.printf("[ACAB] Offline buffer %s\n", on ? "ENABLED" : "disabled");
        }
        // "Record everything": also buffer uncategorized nearby devices, and re-arm capture on a
        // timer, so a board left unattended can answer "did anything come by at all" instead of
        // only "did a KNOWN signature come by". Deploy-and-leave only. See the long note in
        // det_log.h, including the auto-wipe tradeoff the app must surface where the user flips it.
        if (doc["bufall"].is<bool>()) {
            bool on = doc["bufall"].as<bool>();
            detLogSetBufferAll(on);
            Serial.printf("[ACAB] Offline buffer: record-everything %s\n", on ? "ENABLED" : "disabled");
        }
#ifdef ACAB_CAPTURE_BUILD
        // {"mark":"<label>"} - ground-truth marker for field validation. CAPTURE BUILDS ONLY, and
        // that is the point: it exists to justify signatures, not to be one. It changes no
        // classification, emits no detection and returns nothing to the app; the output goes to
        // the serial capture. Ignored entirely by a shipping build, so an app that sends it to a
        // production board simply gets no effect rather than an error.
        if (doc["mark"].is<const char*>()) acabScannerMark(doc["mark"].as<const char*>());
#endif
        if (doc["key"].is<const char*>()) {            // 64 hex chars -> 32-byte at-rest key
            uint8_t k[32];
            if (hexToBytes(doc["key"].as<const char*>(), k, 32)) detLogSetKey(k);
        }
        if (doc["epoch"].is<uint32_t>()) detLogSetEpoch(doc["epoch"].as<uint32_t>());
        if (doc["clearlog"].is<bool>() && doc["clearlog"].as<bool>()) {
            detLogClear();
            Serial.println("[ACAB] Offline buffer erased");
        }
        if (doc["sync"].is<uint32_t>()) { gHistSent = 0; gHistBeginSent = false; detLogStartDrain(doc["sync"].as<uint32_t>()); }
        // Dual-radio black box on the nRF: replay its records, or wipe it (seizure-aware).
        if (doc["bbdump"].is<bool>()  && doc["bbdump"].as<bool>())  acabScannerSendCoProcCmd("DUMP");
        if (doc["bbclear"].is<bool>() && doc["bbclear"].as<bool>()) acabScannerSendCoProcCmd("BCLR");
        // The stock legacy nRF bootloader cannot authenticate an image. In addition to the app's
        // signed-package verification, require the encrypted bonded link and the short RAM-only
        // physical-start window before arming it. The drain re-checks both so a delayed request
        // cannot escape the session that authorized it.
        if (doc["nrfdfu"].is<bool>() && doc["nrfdfu"].as<bool>()) {
            if (nrfDfuMayArmNow()) {
                gNrfDfuReq.store(true, std::memory_order_release);
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
            gPowerOffReq.store(true, std::memory_order_release);
        }
        // Firmware update control. Handled last: an {"ota":{"end"}} reboots the board.
        if (doc["ota"].is<JsonObject>()) handleOtaControl(doc["ota"].as<JsonObject>());
        acabBleUpdateStatus();
    }
};

void acabBleBegin(const char* deviceName, const char* fwLabel, bool startAdvertising) {
    gFwLabel = fwLabel ? fwLabel : "ACAB-ouispy";
    if (!gJsonMux) gJsonMux = xSemaphoreCreateMutex();   // guards the shared JSON scratch pool
    if (!gNotifyMux) gNotifyMux = xSemaphoreCreateMutex();   // serializes every setValue+notify pair

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
    // UAF guard: pre-grow gStatChar's value buffer to NOTIFY_MAX now, before any client can connect.
    // NimBLE's setValue reallocs-to-grow OUTSIDE its read critical section, so a growth realloc racing a
    // peer ATT READ is a use-after-free. Ratcheting capacity to the max here means every later status
    // frame (all <= NOTIFY_MAX) overwrites in place and never reallocs. The placeholder is valid empty
    // JSON ("{}" + trailing spaces) so a read landing before the first real status still decodes clean.
    { uint8_t warm[NOTIFY_MAX]; memset(warm, ' ', sizeof(warm)); warm[0] = '{'; warm[1] = '}';
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

// Build a detection record into `buf` (returns length). For replay set hist=true and
// pass seq + atUnix (atUnix==0 -> "approx":true), plus whenMs/bootCount so the app can verify or
// redo the time reconstruction and bracket an unanchored boot. NOTE: mirrors the field set in
// acabBleNotifyDetection below - keep the two in sync (or consolidate later).
// `elide` trims optional RID enrichment for a small-MTU live notify; see detect_elide.h for the
// order and why. 0 (the default, and what the replay path always passes) is the full record.
static size_t serializeDetection(const AcabDetection& d, bool isNew, char* buf, size_t bufsz,
                                 bool hist, uint32_t seq, uint32_t atUnix,
                                 uint32_t whenMs = 0, uint32_t bootCount = 0,
                                 uint8_t elide = ACAB_ELIDE_NONE) {
    char macStr[18];
    acabFormatMac(d.mac, macStr);
    JsonPoolLock jp;
    JsonDocument doc(jp.alloc());
    doc["t"]    = (int)d.type;
    doc["s"]    = (int)d.src;
    doc["meth"] = (int)d.method;
    doc["c"]    = d.confidence;
    doc["mac"]  = macStr;
    doc["rssi"] = d.rssi;
    if (d.name[0])   doc["name"] = d.name;
    if (d.id[0])     doc["id"]   = d.id;
    if (d.detail[0]) doc["det"]  = d.detail;
    // BLE mfg-specific company ID, for diagnosability (ble-protocol.md): the glasses and tracker
    // detectors key on it, so the detail screen can show which company ID the board actually saw.
    if (d.companyId && acabElideKeeps(ACAB_FIELD_CID, elide)) doc["cid"] = d.companyId;
    if (d.lat || d.lon)           { doc["lat"]  = d.lat;  doc["lon"]  = d.lon; }
    if (d.gpsAgeMs)               doc["gage"] = (uint32_t)(d.gpsAgeMs / 1000);   // GPS fix age (s)
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
    doc["new"] = isNew;
    if (hist) {
        doc["hist"] = true;
        doc["seq"]  = seq;
        if (atUnix) doc["at"] = atUnix; else doc["approx"] = true;
        // The raw reconstruction inputs, sent whether or not the board could resolve "at" itself.
        // "at" is never a clock reading: the board has no RTC, so it is always derived from a
        // per-boot anchor. Shipping the inputs lets the app verify that derivation, redo it against
        // its own anchor history (which outlives board reboots and factory resets), and bracket a
        // record whose boot was never anchored instead of showing a bare "time unknown".
        doc["ms"]   = whenMs;
        doc["boot"] = bootCount;
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

    if (!gDetChar || !gConnected || !detLogDraining()) return;
    // Wait for the MTU exchange before draining. At the 23-byte default gPeerMtu, notifyCap() is
    // 20 bytes - smaller than any replay frame (and the hist:begin lead-in) - so every record would
    // fail the len <= notifyCap() gate below AND be consumed anyway (detLogNextForDrain commits
    // ++gDrain before we can inspect it), draining the whole buffer as skips and emitting
    // hist:begin(n=large)/hist:end(n=0). The app always negotiates 512; this just waits for it.
    if (gPeerMtu <= 23) return;
    // Back-pressure: only push a replay frame while the mbuf pool has headroom, so we never blast
    // into a full pool where notify() would silently drop the record. This also yields to live
    // notifies (which draw from the same pool), so a crowd just slows the drain instead of breaking
    // it. If we're low, skip this tick and let the pool drain (delay(20) in loop paces the retry).
    if (os_msys_num_free() < DRAIN_MBUF_MIN) return;

    char buf[512];
    DetLogReplay r;
    if (!gHistBeginSent) {
        // Lead-in so the app can show a determinate "X of N". N is the exact pending count (not
        // status "buf", which is total ring occupancy). The {"hist":"end","n":N} sentinel closes it.
        // "from" is the resume point (first seq this drain will send): after a board-side wipe
        // reset the seq generation, the app rebases its persisted cursor to from-1 so the
        // end-of-drain checkpoint lands in the new generation instead of re-replaying forever.
        gHistBeginSent = true;
        size_t len;
        { JsonPoolLock jp; JsonDocument doc(jp.alloc());
          doc["hist"] = "begin";
          doc["n"]    = detLogPendingDrain();
          doc["from"] = detLogDrainFrom();
          len = serializeJson(doc, buf, sizeof(buf)); }
        { NotifyLock nl; gDetChar->setValue((uint8_t*)buf, len); gDetChar->notify(); }
        return;
    }
    // Burst: up to DRAIN_BURST_MAX records per pass. Re-check the mbuf headroom before EVERY
    // notify - one 200-500B frame can consume several ~292B msys blocks, so a single up-front
    // check could still blast the pool - and re-check the connection/drain state each
    // iteration, since a disconnect callback on the NimBLE host task can land mid-burst.
    // NotifyLock stays per-record so live detections and OTA notifies interleave with the burst.
    for (int i = 0; i < DRAIN_BURST_MAX; i++) {
        if (!gConnected || !detLogDraining()) return;
        if (os_msys_num_free() < DRAIN_MBUF_MIN) return;
        if (detLogNextForDrain(&r)) {
            size_t len = serializeDetection(r.d, false, buf, sizeof(buf), true, r.seq, r.atUnix,
                                            r.whenMs, r.bootCount);
            if (len > 0 && len <= notifyCap()) {     // skip an over-MTU record; never send truncated JSON
                { NotifyLock nl; gDetChar->setValue((uint8_t*)buf, len); gDetChar->notify(); }
                gHistSent++;
            }
        } else {
            size_t len;
            { JsonPoolLock jp; JsonDocument doc(jp.alloc());
              doc["hist"] = "end";
              doc["n"]    = gHistSent;
              len = serializeJson(doc, buf, sizeof(buf)); }
            { NotifyLock nl; gDetChar->setValue((uint8_t*)buf, len); gDetChar->notify(); }
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

// ONE-SHOT expanded diagnostic, pushed through the STATUS characteristic.
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
    char buf[512];
    size_t len;
    {
    JsonPoolLock jp;
    JsonDocument doc(jp.alloc());
    doc["diag"]   = true;                                  // marks this as the one-shot, not periodic
    doc["sdrop"]  = acabScannerSinkDropTotal();
    doc["sdDeliv"]= acabScannerSinkDropDeliverOnly();      // benign: a missed live notify re-arrives
    doc["sdBuf"]  = acabScannerSinkDropBuffered();         // THE ONE THAT COSTS EVIDENCE
    doc["sdRepl"] = acabScannerSinkDropReplay();           // lost from one dump attempt, ring intact
    doc["sqHigh"] = acabScannerSinkHighWater();            // deepest the queue has been, of 32
    doc["nElide"] = acabBleNotifyElidedCount();            // live notifies that fit only after trimming
    doc["nOver"]  = acabBleNotifyOverCapCount();           // live notifies lost even fully trimmed
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
            doc["cd"]     = false;          // present-but-invalid, i.e. truncated or corrupted
            doc["cdSize"] = cd.sizeBytes;
        }
    }
    len = serializeJson(doc, buf, sizeof(buf));
    }
    if (len > 0) {
        NotifyLock nl;
        gStatChar->setValue((uint8_t*)buf, len);
        if (gConnected && len <= notifyCap()) gStatChar->notify();
    }
    // Serial too, so a USB-only bench sees the same numbers without an app.
    Serial.printf("[diag] sink drops: total=%u deliver-only=%u buffered=%u replay=%u  qhigh=%u/%u\n",
                  (unsigned)acabScannerSinkDropTotal(), (unsigned)acabScannerSinkDropDeliverOnly(),
                  (unsigned)acabScannerSinkDropBuffered(), (unsigned)acabScannerSinkDropReplay(),
                  (unsigned)acabScannerSinkHighWater(), 32u);
}

// Rebuild the status JSON and update the characteristic (notify if connected).
void acabBleUpdateStatus() {
    if (!gStatChar) return;
    char buf[512];
    size_t len;
    {
    JsonPoolLock jp;
    JsonDocument doc(jp.alloc());
    char fwbuf[40];
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
    doc["gps"]    = (gPhoneGpsMs != 0) && (millis() - gPhoneGpsMs < 60000);
    doc["buf"]    = detLogCount();          // stored offline records
    doc["bufon"]  = detLogEnabled();        // buffering opt-in state
    // Only sent when ON. Absent means off, which is the default, so the common case costs no MTU
    // bytes - same trick as "ledon" above. The app needs it to reconcile the switch AND to keep
    // showing the weakened-auto-wipe warning for as long as the mode is actually armed.
    if (detLogBufferAll()) doc["bufall"] = true;
    // Ring saturation: the TAIL of the stored log is censored. Sent only when true, same idiom.
    // This is not a settings-screen detail - the app must show it BESIDE THE LOG, because without
    // it a full-looking replay cannot be distinguished from one that stopped recording days early.
    if (detLogSaturated()) doc["bufsat"] = true;
    // Latched flash fault bitmask. A nonzero value means the ring stopped accepting writes rather
    // than pretending evidence was stored; only a fully successful physical wipe clears it.
    if (uint32_t faults = detLogFaults()) doc["buferr"] = faults;
    if (detLogWipePending()) doc["wiping"] = true;   // deferred buffer erase still sweeping; absent = idle
    doc["desert"] = desertIsEnabled();      // Desert mode (report every device in range)
    doc["ign"]    = acabScannerIgnoreCount();  // ignore-list size, for app reconciliation
    doc["wat"]    = acabScannerWatchCount();    // watchlist size, for app reconciliation
    doc["wseen"]  = acabScannerWifiSeen();      // two-radio diag: 802.11 mgmt frames seen
    doc["bseen"]  = acabScannerBleSeen();       // BLE adverts ingested (= the nRF's forwards in dual mode)
    // Sink-queue drops, TOTAL only - the per-category split rides the {"diag":true} reply so the
    // periodic JSON stays under the ATT budget. Emitted only when nonzero: on a healthy board this
    // is always 0, and spending MTU on a constant would push a fuller status past notifyCap().
    // Nonzero means the sink queue overflowed; the buffered share is the part that cost evidence.
    if (uint32_t sd = acabScannerSinkDropTotal()) doc["sdrop"] = sd;
    if (acabScannerHasCoProc()) doc["nbb"] = acabScannerCoProcBbCount();  // nRF black-box record count
    if (gBatteryPct >= 0)       doc["bat"] = gBatteryPct;                 // battery %, sense-divider boards only
#ifdef ACAB_DUAL_RADIO
    // Co-processor (nRF) liveness for the app's "bluetooth detection offline" warning. Always
    // emitted on the dual board: the app only warns when it is present AND false, so an absent
    // key (older firmware / single-radio) never trips it. See the cross-target contract.
    doc["co"]  = acabScannerCoProcAlive();
    // Companion nRF app version, for the app's "nRF update available" check (BLE DFU). Emit only
    // once heard (>=0) so single-radio builds and a not-yet-announced nRF never send a stray -1.
    { int nrfv = acabNrfVersion(); if (nrfv >= 0) doc["nrfv"] = nrfv; }
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
    // Update the characteristic value UNCONDITIONALLY, before the notify guard: the status is
    // READable, and the apps poll it (~every 5 s) as a fallback, so a READ must always return the
    // freshest status even when the notify below is skipped for a small negotiated MTU.
    // Notify only a connected peer (no client = nothing to notify, and no misleading "skipped" spam on a
    // USB-only bench). A fuller status must never ride out truncated past the peer's negotiated MTU, which
    // would hand the app invalid JSON; skip only the notify then - the READ value set above stays fresh and
    // the apps' ~5 s status poll covers it. The setValue+notify pair is serialized against the other
    // characteristic writers (see NotifyLock); the setValue stays unconditional so a READ is always fresh.
    if (len > 0) {
        NotifyLock nl;
        gStatChar->setValue((uint8_t*)buf, len);
        if (gConnected && len <= notifyCap()) gStatChar->notify();
    }
    if (gConnected && len > 0 && len > notifyCap()) {
        Serial.printf("[ACAB] status JSON %u B over MTU cap %u - notify skipped (peer MTU %u)\n",
                      (unsigned)len, (unsigned)notifyCap(), (unsigned)gPeerMtu);
    }
}

bool acabBleClientConnected() { return gConnected; }

// Latest phone GPS the app pushed, if it arrived within maxAgeMs. Returns false
// (leaving lat/lon untouched) when there's no fresh fix.
bool acabBleGetPhoneGps(double* lat, double* lon, uint32_t maxAgeMs, uint32_t* ageMs) {
    portENTER_CRITICAL(&gGpsMux);
    uint32_t ms = gPhoneGpsMs; double la = gPhoneLat, lo = gPhoneLon;
    portEXIT_CRITICAL(&gGpsMux);
    if (ms == 0) return false;
    uint32_t age = millis() - ms;
    if (age > maxAgeMs) return false;
    if (lat)   *lat   = la;
    if (lon)   *lon   = lo;
    if (ageMs) *ageMs = age;
    return true;
}
