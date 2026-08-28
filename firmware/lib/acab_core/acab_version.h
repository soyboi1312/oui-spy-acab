/*
 * ACAB - All Cameras Are Beacons
 * Single source of truth for the firmware version.
 *
 * This default value is what oui-spy and mesh-detect report; bump it here for those
 * builds. The beacon board carries its OWN -DACAB_FW_VERSION in platformio.ini (that is
 * the line to bump for a beacon-board release), so it does not read this default.
 *   oui-spy     banner, advertised version, status JSON ("fw")
 *   mesh-detect serial banner
 *   beacon-board overrides via -DACAB_FW_VERSION (platformio.ini)
 *
 * It's a string literal so it can be glued onto adjacent literals (e.g.
 * "ACAB-ouispy " ACAB_FW_VERSION). Not called version.h, to avoid clashing with
 * the C++ standard <version> header.
 */
#ifndef ACAB_VERSION_H
#define ACAB_VERSION_H

// Default single source of truth. A build env may override it (the beacon-board carries
// its own version via -DACAB_FW_VERSION so OTA's version-guard can compare builds); oui-spy
// and mesh-detect leave it at the default. Keep it "a.b[.c]" so OTA can parse and compare.
//
// KEEP EVERY DOTTED FIELD UNDER 1024. acabOtaVersionPack (ota_policy.h) packs the version into
// three 10-BIT FIELDS and REFUSES a field past 1023 as malformed (packs to 0, which every OTA
// gate hard-rejects; it used to clamp, which aliased 2.0.1023 with 2.0.9999). A four-digit
// field above 1023 is therefore un-shippable over the air: the apps compare unclamped, would keep offering
// the update, and the board would refuse it forever. Bump the MINOR when the patch field runs out.
//
// 2.0.6: adds capture instrumentation for i-PRO BWC4000 activation accessories and Getac
//        BC-02/BC-03 cameras plus TB/HS vehicle triggers. These are capture candidates, not
//        production classifiers, until a ground-truthed advert supplies a stable passive value.
//        Phone companions also expose Live Mode by default and add scoped device mutes.
// 2.0.5: the two-review hardening round. No new detection categories; the wire, the grading and
//        the radio hot path got safer.
//        WIRE: `cid` (BLE manufacturer company ID) is now actually emitted in every detection
//        record - both apps had parsed, rendered and exported it while the firmware never sent
//        it, so the glasses/tracker diagnosability story was fiction. First field elided on a
//        tight-MTU live notify; replay records always carry it.
//        GRADING: the "*-FALCON" SSID branch is gated on self-attestation like its "Flock-"
//        sibling, so a probe REQUEST regrades to M_PROBE/72 instead of earning beacon-tier 85;
//        both remaining raw-strncpy SSID copies clamp through acabSanitizeAscii; a Raven vendor
//        UUID is recognized past the 16-slot svc16 cap (evidence displaces filler).
//        HOT PATH: detLogBufferAll() no longer runs inside the dedup critical section (nothing
//        but plain memory access belongs inside portENTER_CRITICAL; the flag read itself is
//        lock-free, see its definition in det_log.cpp).
//        PAIRING: mesh-detect now enables the connect-time pairing gate (USB replug arms the
//        window, cellAbsent=true); previously any stranger in radio range could bond and reach
//        clearlog/key/toggles.
//        OTA: acabOtaVersionPack refuses a dotted field past 1023 as malformed instead of
//        saturating (2.0.1023 no longer aliases 2.0.5000); both apps validate the running
//        version as ASCII digits only (fullwidth/Arabic-Indic/Devanagari digits could spoof
//        the >= compare and disarm rollback) with cross-platform leading-dash parity.
//        Plus UBSan enum clamp on ODID status, uint32/int16 clamps at every app decode
//        boundary, and the dev-OTA-key fingerprint pinned in the release verifier.
//        ALSO IN THIS CUT (landed in the same tree before the hardening round): BLE proto 1->2
//        (the nrfdfu physical-window re-gating is the breaking part), OTA project-identity
//        binding + health-gated trial confirmation + durable trial records, Desert toggle NVS
//        persistence, det_log fault latches/saturation + record-everything support, and the
//        drone vendor-OUI table rework (MA-M/MA-S prefix narrowing, Autel 18:D7:93 dropped).
// 2.0.4: Arlo, and the first SSID match in the netcam category.
//        DETECTION: Arlo Technology netcam OUIs 59 -> 62 (A4:11:62, FC:9C:98, 48:62:64). Arlo had
//        been named on netcam_signatures.h's "why not" line with NO reason while Nest and Blink
//        each had one, i.e. swept in by association. It holds 3 blocks and ships nothing with a
//        radio but cameras, doorbells and the hubs that serve them, so it passes the narrowness
//        test more cleanly than Wyze. FIRST VENDOR HERE ADMITTED ON OUR OWN CAPTURE rather than a
//        registry pull: the 2026-07-24 drive logged 12 distinct Arlo devices, 3 of them
//        broadcasting an ARLO_VMB_ SSID. Still validated=0 - the SSID proves the hardware, only
//        an eyeball proves a camera.
//        NEW MATCH METHOD: NETCAM_SSID_ARLO_PREFIX ("ARLO_VMB_", plus the uncaptured NETGEAR-era
//        "NTGR_VMB_"), M_SSID at confidence 88 - ABOVE every OUI tier in that table including the
//        eyeball-validated 75, for the same reason the Flock SSID earns 88: the device states its
//        own vendor instead of being inferred from a block. Reports "Arlo base station", NOT
//        "camera", because a hub is what the SSID proves. Checked BEFORE the OUI so a weaker 65 on
//        the same frame cannot win. WiFi-only on purpose (the discontinued Arlo Security Light is
//        BLE, and a porch light must never be labelled a camera).
// 2.0.3: the BLE link round, plus two detection additions.
//        DETECTION: Google Find Hub / FMDN separated trackers (Eddystone service data
//        0xFEAA, frame type 0x41 ONLY - the near-owner 0x40 form is deliberately not
//        matched, see tracker_detect.cpp). This closes the second-largest tracker
//        network in the US and makes the follow-me scorer mean something for the
//        Android ecosystem, which it previously did nothing for. Netcam OUIs 43 -> 59:
//        Ezviz (14 blocks, Hikvision's consumer brand with its OWN registrations, so the
//        Hikvision rows never caught it), Lorex, Swann. TP-Link/Tapo and Foscam were
//        evaluated and REJECTED with the reasoning recorded in netcam_signatures.h.
//        BLE LINK: CCCD slots raised to 32 so the 8 bond slots are real - the store
//        saturated after 2 fully-subscribed bonds, and a CCCD overflow calls
//        ble_gap_unpair_oldest_except(), i.e. IT DELETES A BOND, with nothing on the wire to
//        say so. Bond slots 3 -> 8. The firmware version no longer goes out in the scan
//        response. Advertising re-arms after GAP preemption, so a board cannot end up silently
//        un-advertising and indistinguishable from a dead one. New GAP/pairing serial
//        diagnostics (enc_change status, disconnect reason, peer identity), which are what
//        named every fault in this round instead of guessing. Address privacy (rotating RPA) is
//        implemented and OFF: proven on air and on Android, and iOS cannot connect through it.
//        Read ACAB_BLE_PRIVACY in acab_ble_service.h before touching that flag.
// 2.0.2: everything in 2.0.1 plus its review round. Network cameras got their own buzzer
//        pattern and now honour their own opt-in; the glasses classifier scores all three
//        match surfaces instead of returning on the first; the WiFi Axon detail strings match
//        the apps' exact-match contract. Also the maker-led row title: both apps now lead an
//        unnamed detection with the manufacturer the device broadcast.
// 2.0.1: glasses 0x01AB un-gated on ground truth, plus the 16-bit member-UUID and HeyCyan
//        UUID surfaces; Ring/Wyze/Anker-eufy camera OUIs; the Axon OUI matched on WiFi.
//        All of it lives in lib/acab_core, so these builds get it too.
// 2.0.0: the Colonel Panic builds pick up the full v2 detection set the beacon board ships
// with (offline buffer, watchlist/custom category, ignore list, refreshed OUIs, glasses).
#ifndef ACAB_FW_VERSION
#define ACAB_FW_VERSION "2.0.6"
#endif

#endif // ACAB_VERSION_H
