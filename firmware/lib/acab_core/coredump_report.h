/*
 * ACAB - surface the ESP-IDF core dump that the board is ALREADY capturing.
 *
 * WHY THIS EXISTS. The shipped partition table (`default_8MB.csv`) already carries
 * `coredump @ 0x7F0000, 64 KB`, and IDF's espcoredump (flash target, ELF format) is already
 * compiled into the image. Nothing in ACAB has ever read it. So every panic this product has had
 * in the field wrote a full post-mortem to flash and then sat there, invisible, until the next
 * flash erase took it. This header is the smallest thing that changes that: one line on the serial
 * console at boot, and the same fields in the {"diag":true} reply.
 *
 * DELIBERATELY NOT TOUCHING THE PARTITION TABLE. A resize would invalidate every board in the
 * field (the table is flashed once, and a mismatched table bricks the OTA layout), and truncation
 * has not been PROVEN yet - it is expected around ~9 tasks. The boot check reports a truncated or
 * invalid dump as such rather than pretending, which is the honest handling either way.
 *
 * WHAT THE SUMMARY ACTUALLY CONTAINS - this trips people up. esp_core_dump_summary_t carries the
 * excepting task, PC, backtrace, dump version, and the APP ELF SHA256. It does NOT carry a
 * semantic firmware version. So:
 *   - print the ELF SHA, and let the release provenance map SHA -> version;
 *   - NEVER label a dump with the running ACAB_FW_VERSION. A retained dump can predate the current
 *     boot and SURVIVES AN OTA, so the running version is frequently not the version that crashed;
 *   - label the current boot's esp_reset_reason() as `last_reset`, not `dump_reset`, for the same
 *     reason: it describes this boot, not necessarily the dump.
 *
 * THIS PARTITION IS A SECOND AT-REST SURFACE. det_log builds a deliberate posture around its
 * 64 B ring: opt-in and off by default, AES-CTR at rest, key removal on disable, a boot-count
 * auto-wipe so a board out of its owner's hands self-cleans, and a power-loss-resumable erase.
 * A retained dump needs its own erase state because it is a different partition. An IDF ELF
 * dump captures each task's LIVE STACK, and the stack that matters is the NimBLE host task's: it
 * decodes the at-rest key into a local buffer, parses the phone's {"lat","lon"} on the same
 * stack, and unpacks decrypted records there during a replay. So a panic can persist an in-flight
 * detection - MAC plus phone-pushed coordinates - on a board that never opted into the buffer at
 * all, and it survives {"clearlog"} and the auto-wipe, both of which report success. DRAM capture
 * is off, so this is only what happened to be on a live frame at the panic, but that is exactly
 * the material the rest of the design goes to lengths to protect.
 *
 * EXPLICIT INTENT IS DURABLE AND INDEPENDENT. `clearlog`, an at-rest key change, and every
 * `buffer:false` write advance an NVS-backed erase-generation token in det_log. That token is
 * independent of the ring's shared `wipe` level, survives power loss, and is cleared only after
 * this partition is erased (or positively found empty). A new request supersedes an in-flight
 * generation without being acknowledged by the older completion. This closes both historical
 * gaps: an explicit clear while a ring sweep was already pending, and a crash/power loss between
 * the ring and dump erases. The boot-count auto-wipe intentionally does NOT create this explicit
 * token: it preserves the post-mortem the boot report has just told the operator how to decode.
 *
 * COVERAGE IS PER-MAIN, WHICH IS THE PART THAT GOES WRONG. acabCoredumpWipeTick() carries the
 * whole trigger rule, so each product main spends exactly one line on it: beacon-board / oui-spy
 * (src/beacon-board/main.cpp) and mesh-detect (src/mesh-detect/main.cpp) both call it. A NEW main
 * that links acab_core inherits this exposure and must call acabCoredumpProbe() +
 * acabCoredumpWipeTick(), or its {"clearlog"} reports success with the dump still in flash.
 * (src/odid-sim is the one build that needs neither: a bench transmitter that links none of
 * acab_core, mounts no ring, and runs no GATT service.)
 *
 * WHY THE PUMP IS NOT BURIED IN det_log INSTEAD, which would make every main inherit it for free.
 * det_log owns and host-tests the durable INTENT, but esp_core_dump_* is an IDF-only dependency;
 * pushing the physical dump operation into that host-tested file would cost the suite that guards
 * the ring. coredump_report consumes the token from loop(), where the cache-off block erase is
 * safe, and reports completion back to det_log.
 */
#ifndef ACAB_COREDUMP_REPORT_H
#define ACAB_COREDUMP_REPORT_H

#include <stdint.h>
#include <stdbool.h>

/// Cached, printable view of the retained dump. Read once at boot (the flash read is not free and
/// the contents cannot change while we run) and reused by the diag reply.
struct AcabCoredumpInfo {
    bool     present;        ///< a dump was found AND passed esp_core_dump_image_check()
    bool     corrupt;        ///< not positively empty, but unreadable/invalid; erase is required
    uint32_t sizeBytes;      ///< image size when metadata was readable; may be 0 on access failure
    char     task[24];       ///< crashing task name, empty when unavailable
    uint32_t pc;             ///< program counter at the exception
    char     elfSha[41];     ///< app ELF SHA256, hex; maps to a version via release provenance
    uint32_t dumpVersion;    ///< core-dump format version
};

/// Read + cache the retained dump's summary. Only ESP_ERR_NOT_FOUND is treated as positively
/// empty. Every other incomplete/error state is fail-closed as corrupt so an explicit wipe cannot
/// be acknowledged over possibly retained stack bytes. Call once, early in setup(), after Serial
/// is up so the one-line report is visible.
void acabCoredumpProbe();

/// The cached result. Zeroed until acabCoredumpProbe() runs.
const AcabCoredumpInfo& acabCoredumpInfo();

/// Print the one-line `[coredump]` report (or nothing when there is no dump and no corruption).
void acabCoredumpPrint();

/// Erase the retained dump from flash and drop the cached summary. See the SECOND AT-REST SURFACE
/// note above: nothing else erases this partition, so every path that means "erase what this board
/// stored" has to call this or it leaves a copy behind while reporting success. Returns true when
/// there is nothing retained, so a wipe path can call it unconditionally.
///
/// Costs one 64 KB block erase, the same unit det_log's chunked wipe budgets at ~100-250 ms with
/// the flash cache off. Call it from the LOOP TASK, like detLogEraseTick, never from the NimBLE
/// host task - a cache-off stall there freezes GATT for both cores.
///
/// This is NOT part of the boot report. acabCoredumpPrint() tells the reader to decode the dump
/// against the ELF with the printed SHA, and that needs the binary still in flash; erasing at boot
/// would make the printed instruction impossible to follow.
bool acabCoredumpErase();

/// Pump the erase from loop(), once per pass, on the LOOP TASK. Consumes det_log's NVS-backed
/// explicit erase generation, including one restored after power loss; no inference from the
/// shared ring-wipe edge is involved. It waits for the ring sweep so one pass does not take two
/// 64 KB erases, but the wait is bounded (see kRingSweepWaitMs): a missing/stalled ring cannot
/// strand the dump. A failed dump erase keeps the token for a reboot retry (or a newer explicit
/// request) without hammering the flash each pass. On the ordinary no-token path this costs one
/// locked integer read.
void acabCoredumpWipeTick();

#endif // ACAB_COREDUMP_REPORT_H
