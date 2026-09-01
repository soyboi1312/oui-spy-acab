# Axon body-camera detection (field-validated)

**Status: field-validated, on by default.** As of June 2026 the detector has caught
real Axon body cameras on patrolling officers in the field, so it ships enabled.

## How it works

Axon body cams advertise BLE with a payload signature that survives MAC randomisation
(Axon is moving to rotating BLE MACs, so a MAC-based match alone would not hold), which
is what makes passive detection work. ACAB keys off two public facts:

- **MAC OUI `00:25:DF`**: Axon Enterprise's only IEEE block (MA-L, registered 2010
  as TASER International, updated 2025-01-30). This is the loose match: it flags any
  Axon product (body cam, dock, TASER, fleet gear).
- **The `BWCDEVICE` service-data tag**: a standalone, MAC-independent match (method
  svc-data, confidence 90, detail "BWC DEVICE") that fires with or without the Axon
  OUI - deliberately, because rotating BLE MACs break the OUI path but the tag rides
  in the advert payload. The OUI stays the loose any-Axon-product match at
  confidence 75.

There is also a WiFi path. `axonClassifyWiFi` matches the same `00:25:DF` OUI (and the
Utility BodyWorn OUIs) on WiFi management frames at confidence 65. Axon's WiFi estate is
broader than body cams (docks, evidence terminals, station gear, and Fleet in-car video),
so the type claim is weaker there: the OUI says "an Axon device", not necessarily a body
cam. It is registry-sourced only, not yet field-validated over WiFi.

> Heads up: the unrelated **"Axon Networks Inc."** OUIs (`00:58:28`, `84:70:03`)
> belong to a different, legacy company. Don't use them.

## Field validation

June 2026: driving past multiple officers at different stops, ACAB picked up their
body cams on `00:25:DF`, confirming that Body 3 / Body 4 units advertise on the
public OUI (not a resolvable random address) in normal holstered operation.

## Tuning

`lib/acab_core/axon_detect.*` is data-driven via `AxonSignature`. The registry OUI
loads with `axonUseRegistryCandidate()`; set `usePayload = true` to *require* the
`BWCDEVICE` tag (strictest match) if OUI-only false positives ever appear. It's
enabled by default (`gEnabled = true`); either app (iOS or Android) can toggle it with
`{"axon":true}`, and the choice is NVS-persisted, restored on every board at boot via
`axonRestoreEnabled(true)`.
