# Smart / recording glasses detection (capture-pending)

**Status: `0x01AB` field-validated while worn; the rest signature-sourced, capture-pending.**
The company IDs below are verified against the Bluetooth SIG registry. On 2026-07-31 a
ground-truth capture (three Meta glasses, Ray-Ban and Oakley, worn through a 70-minute,
1568-row capture) confirmed that the glasses advertise the Meta corporate ID `0x01AB`
*while worn*, so `0x01AB` was un-gated: a bare `0x01AB` hit now emits at confidence 45 (the
apps' weak-match "verify this" band, with the Quest caveat kept), token or no token. The
other shared IDs stay gated: `0x058E` (Meta Quest), TCL's `0x0BC6`, and Jieli's `0x05D6`. A
Quest on its own still stays silent; a `0x058E` advert only emits when it co-signals the
`META_RB_GLASS` token that marks the glasses (see the gate below), and `0x0BC6` / `0x05D6`
have no token to rescue them. The eyewear-only IDs ship enabled (like Axon) and report
honestly as "possible recording glasses." Still capture-pending: the `META_RB_GLASS` token's
exact byte framing, and worn-advertising confirmation for Snap and Vuzix.

**The detector reads THREE surfaces, not just manufacturer data.** Most of this page was written
when it read one, so read it with that in mind: the company-ID material below is current and
complete for that surface, and the two service-UUID surfaces added 2026-07-31 are covered under
*Service-UUID surfaces* near the end. The shipped tables for all three live in
[docs/signatures.md](signatures.md), which is the file to trust on values, confidences and gating.

## Its own category, not trackers and not body cam

Recording glasses are a distinct threat and get their own device type,
`ACAB_GLASSES` (`t=9`, label **"Recording glasses"**). They are not folded into the
BLE item-tracker category (those are AirTags and Tiles, a different signature set and
a different privacy story) and not folded into body cam (Axon is fixed body-worn gear on a
single OUI; glasses are consumer camera eyewear keyed off Bluetooth company IDs). Giving
them their own type keeps the map, log, and detail views honest about what was actually
seen.

Camera glasses are worth their own line because they are the covert case: a body cam is
worn openly and a tracker is inanimate, but a person wearing Ray-Ban Meta or Snap
Spectacles is recording the people around them with nothing on the outside that reads as
a camera.

## Verified BLE company IDs

One of the three match surfaces, and the last one the firmware evaluates: the BLE
**manufacturer-specific data** (AD type `0xFF`), whose first two payload bytes are the company ID,
**little-endian**. This is the existing `M_MFG_ID` method (`meth:3`). Keying on the payload
company ID (not the MAC) is deliberate: it survives the BLE MAC randomization that these devices
do, which is the whole point of an external detector. The two service-UUID surfaces are described
under *Service-UUID surfaces* below and use their own methods.

| Company ID | Registrant | Product | Eyewear-specific? | Confidence |
|---|---|---|---|---|
| `0x0D53` | Luxottica Group S.p.A | Ray-Ban Meta frames (EssilorLuxottica) | yes, eyewear-only registrant | higher |
| `0x03C2` | Snapchat Inc | Snap Spectacles camera glasses | yes, Snap's only BLE hardware is Spectacles | higher |
| `0x060C` | Vuzix Corporation | Vuzix camera AR glasses (Blade, M400, Shield, Z100) | yes, eyewear-only registrant | higher (70) |
| `0x058E` | Meta Platforms Technologies, LLC | Ray-Ban / Oakley Meta AI glasses **and** Meta Quest VR | no, shared across Meta hardware | bare hit gated off; token-confirmed only (72) |
| `0x01AB` | Meta Platforms, Inc. | Meta corporate/parent ID, appears across Meta hardware | no, not eyewear-specific | bare hit ships at 45 (weak match); token-confirmed 72 |
| `0x0BC6` | TCL COMMUNICATION EQUIPMENT CO.,LTD. | RayNeo AR/smart glasses (a TCL sub-brand), also TCL phones/tablets/TVs | no, TCL corporate ID | gated off (no token to confirm) |
| `0x05D6` | Zhuhai Jieli Technology Co. | Rogbird VisionPro / Rollme VistaView camera glasses | no, a Bluetooth AUDIO SoC vendor | gated off (no token to confirm) |
| none | RayNeo | RayNeo smart glasses | no dedicated SIG company ID exists | n/a |

**Provenance.** Every company ID above was pulled from the Bluetooth SIG Assigned Numbers
company-ID list (mirrored in the Nordic DB) during the Signatures phase and matched against the
authoritative registrant strings:

- Bluetooth SIG Assigned Numbers (company IDs): https://www.bluetooth.com/specifications/assigned-numbers/
- Nordic company-ID mirror: https://github.com/NordicSemiconductor/bluetooth-numbers-database

Registrant-string notes worth keeping straight:
- `0x0D53` is Luxottica, an eyewear-only registrant. The initial "not found" on the Nordic
  fetch was a truncation false-negative; it is present. This is the cleanest Ray-Ban Meta tell.
- `0x03C2` reads as **"Snapchat Inc"** in the authoritative registry, not "Snap Inc" as it is
  sometimes reported. Snap's only BLE hardware is Spectacles, so it is effectively eyewear-only.
- `0x060C` is **Vuzix Corporation**, an eyewear-only AR maker whose entire hardware line is
  camera-equipped smart glasses (Blade, M400, Shield, Z100). Like Luxottica and Snap it ships
  no phones, watches, or headsets, so a hit is glasses with no shared-hardware caveat, which is
  why it sits in the higher (70) eyewear-only band and needs no payload discriminator. Do **not** confuse
  it with `0x0820` Brilliant Home Technology (a smart-home hub vendor), which is a different
  company from the Brilliant Labs AR-glasses startup and is not a glasses signal.
- `0x0BC6` is TCL's corporate ID (decimal 3014). RayNeo is a TCL-incubated brand and would
  advertise under this shared ID or under a silicon-vendor ID, so a hit here is not
  glasses-specific.
- A full grep of the registry returns **no** entry containing "RayNeo," so there is no clean
  glasses-only detector for RayNeo. It inherits TCL `0x0BC6` or a chipset-vendor ID.

## The Meta Quest false positive, and why we gate it

`0x058E` (Meta Platforms Technologies, LLC) and `0x01AB` (Meta Platforms, Inc.) are
**corporate** BLE company IDs shared across Meta's whole hardware line, most importantly
the Meta Quest VR headsets. A person walking by carrying a Quest advertises the same
`0x058E` company ID as the Ray-Ban/Oakley Meta glasses, so a match on the Meta IDs alone
cannot prove it is glasses. Worse, a Quest advertises from a rotating private address, so a
bare shared-ID match would re-alert on every rotation and the per-MAC Ignore could never
silence it, a permanent false alarm on hardware with tens of millions of units.

So the shipped firmware **gates the bare shared-ID match off** for `0x058E`, TCL's `0x0BC6`,
and Jieli's `0x05D6`. A Quest on its own does not flag as recording glasses. `0x01AB` is the
exception: it was un-gated on the 2026-07-31 ground-truth capture, so a bare `0x01AB` advert
now emits as a weak match at confidence 45 ("Meta: possible recording glasses or Quest"),
token or not. A gated `0x058E` advert only emits when it also carries the `META_RB_GLASS`
token described below, in which case it is reported as confirmed glasses ("Ray-Ban Meta:
recording glasses") with no Quest caveat.
Ray-Ban Meta coverage rides the un-gated `0x01AB`: in the 2026-07-31 capture the worn
Ray-Ban and Oakley Meta frames were only ever heard on `0x01AB`, while the eyewear-only
Luxottica ID `0x0D53` fired zero times. That disproved the earlier plan of leaning on
`0x0D53` as the Ray-Ban Meta fallback and is why the bare-ID gate was lifted for `0x01AB`;
`0x0D53` stays enabled in the table but is not what caught real worn frames in our capture.
The "nearby glasses" Android app documents the same underlying overlap, that matches on the
Meta IDs "will also trigger on other Bluetooth-enabled products from the same companies,
including VR headsets," and where it falls back on visual context, ACAB surfaces a weak match
on the bare `0x01AB` hit (and stays silent on the still-gated Meta IDs) rather than guess.

Luxottica (`0x0D53`), Snapchat (`0x03C2`), and Vuzix (`0x060C`) sidestep the ambiguity
entirely, because those registrants only ship eyewear, so they carry higher confidence with
no payload discriminator needed. TCL `0x0BC6` is shared with phones and TVs and has no token
to rescue it, so it stays gated off until a field capture gives RayNeo a clean discriminator.

## Capture-pending: what to confirm in the field

Two things gate promoting this from capture-pending to field-validated:

1. **Advertise-while-worn.** Confirmed for Meta on 2026-07-31: worn Ray-Ban and Oakley Meta
   frames broadcast the `0x01AB` company ID passively while worn, and the Luxottica `0x0D53`
   did not fire at all. Still open for Snap Spectacles and Vuzix: confirm those actually
   broadcast their company ID passively while worn and recording (not only during pairing),
   and the same for any Luxottica frame on `0x0D53`. The device **name** does identify the
   glasses, but
   per Help Net Security's reporting that name is generally only exposed during pairing, so
   it is rarely visible in the field against someone who paired in advance. Net: continuous
   field detection has to rely on the payload surfaces - company ID, service UUIDs, and for
   Meta the payload token below - not the name.
2. **A Quest discriminator (already gating).** The way to separate Ray-Ban/Oakley Meta
   glasses from a Quest under the shared `0x058E` ID is a manufacturer-data payload
   **token**, not a service UUID: the glasses' BLE manufacturer data is reported to carry
   the ASCII token **`META_RB_GLASS`**, which detection projects (the Spectacle keychain,
   the "nearby glasses" app) parse before alerting. No 16-bit service UUID has been
   documented that tells glasses from a Quest either: the member UUIDs the firmware does
   match are split by REGISTRANT, which is an inference about who ships what, not a
   glasses-versus-headset discriminator. What the shipped firmware relies on is narrower
   than this section used to claim: a bare **`0x058E`** advert stays silent and emits only
   when the token co-signals, which raises the hit to a confident glasses call and drops the
   Quest caveat, while the corporate parent ID **`0x01AB`** was un-gated on 2026-07-31 and
   now emits a conf-45 weak match on its own, token or not. What is still capture-pending is
   confirming the token's exact byte framing against a real worn-and-recording advert, so
   for now the token is only a confidence bump layered on the company-ID (`M_MFG_ID`) match,
   never a standalone signal.

## Service-UUID surfaces

Added 2026-07-31. Manufacturer data is not the only place a vendor names itself, so the detector
also reads two service-UUID surfaces. Both are payload-borne, so they survive MAC randomization
the same way the company ID does, and both work on an advert that carries **no** `0xFF` record at
all, which is why the firmware evaluates them before it looks for manufacturer data:

- **16-bit SIG member service UUIDs** (method `M_SERVICE_UUID`, `meth:4`), read from the AD
  `0x02`/`0x03` UUID lists and the first two bytes of an AD `0x16` service-data record. A
  **separate namespace** from company IDs, and easily confused with them: `0xFEB7` is not company
  ID `0xFEB7`. Shipped: Meta `0xFEB7` / `0xFEB8` at conf 45 un-gated, Snap `0xFE45` at conf 70,
  and Meta Platforms Technologies' `0xFD5F` gated off for the same Quest reason as `0x058E`.
- **The HeyCyan SDK's 128-bit service UUID** (method `M_SERVICE_DATA`, `meth:8`), read from the AD
  `0x06`/`0x07` 128-bit lists or AD `0x21` service data, at conf 68. It names the glasses
  SOFTWARE rather than a corporate registrant, so it carries neither the Quest nor the earbud
  ambiguity. It must only ever match on the **full 16 bytes**: it shares its whole base with
  Apple's ANCS UUID, so a prefix match would fire on most notification-consuming wearables.

**All three surfaces are scored, and the best confidence wins, not the first hit.** Order decides
ties only, and the firmware's order is HeyCyan, then 16-bit member UUID, then company ID, with a
`<=` comparison so an equal-confidence later surface never displaces an earlier one. An advert
carrying both Snap's `0xFE45` (70) and Snap's `0x03C2` (70) therefore reports `meth:4`.

The gating, confidences and provenance for every row live in
[docs/signatures.md](signatures.md); the wire fields are in
[docs/ble-protocol.md](ble-protocol.md).

## The beacon advantage

The reason an external radio is the right tool here: the phone-only "nearby glasses" apps
are hamstrung by iOS, which does not let a backgrounded app run a continuous BLE scan, so
they only catch glasses when the app is open in the foreground. ACAB's beacon is a
dedicated radio that scans 24/7 regardless of what your phone is doing, then pushes hits
to the app over its own link. It sidesteps the iOS background-scan limit that blocks the
phone-only approach, and the buzzer means it works with the phone away entirely.

## Config

Toggled with `{"glasses": true|false}` on the Config characteristic, mirroring the
`axon` / `tracker` enable pattern, NVS-persisted, and **on by default** (like Axon). The
Status JSON reports it as `"glasses"` beside `"axon"` and `"tracker"`. Detail strings name
the vendor and say "possible recording glasses"; a bare `0x01AB` hit emits as a weak match at
confidence 45, the still-gated shared IDs (`0x058E`, `0x0BC6`, `0x05D6`) do not emit on their
own, and a token-confirmed Meta hit reports as "Ray-Ban Meta: recording glasses" with no
Quest caveat. One switch covers all three surfaces; there is no per-surface toggle, and the
`meth` field on the wire (`3` mfg ID, `4` member UUID, `8` HeyCyan 128-bit) is what says which
one fired. See [docs/ble-protocol.md](ble-protocol.md) for the wire fields and
[docs/signatures.md](signatures.md) for the signature tables.

## Sources

- Bluetooth SIG Assigned Numbers: https://www.bluetooth.com/specifications/assigned-numbers/
- Nordic company-ID mirror: https://github.com/NordicSemiconductor/bluetooth-numbers-database
- Help Net Security, on the glasses name being pairing-only: https://www.helpnetsecurity.com/
