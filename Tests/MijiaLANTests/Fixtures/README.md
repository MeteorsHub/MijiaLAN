# Reviewed specification projections

These fixtures are hand-reviewed projections of public specification pages, initially reviewed 2026-11-04 and extended with the household reports received 2026-11-06. They are **not** raw device responses or complete official instance JSON. Device URNs/versions, service/property IDs, formats, access and the listed ranges/enums are preserved for the selected regression cases; unrelated services and some options are omitted. Property/service `type` fields use semantic short names, not invented full URNs. They are test resources only and do not replace the App’s cached schemas.

Sources:

- https://home.miot-spec.com/spec/dooya.motor.dc1545 — motor-controller v1; MIoT position 0=closed, 100=open; motor-control is write-only.
- https://home.miot-spec.com/spec/xiaomi.derh.13l — dehumidifier v2; environment temperature is float, step 1.
- https://home.miot-spec.com/spec/iot.tow_w.jd015 — towel-rack v1; surface temperature and setpoint are not room temperature.
- https://home.miot-spec.com/spec/giot.heater.v13daf — heater v1; heater and light are separate services; zero fault enum has placeholder label `null`.
- https://home.miot-spec.com/spec/xiaomi.pet_waterer.70m2 — fountain v2; two distinct out-water-interval properties at 2.7/2.11.
- https://home.miot-spec.com/spec/xiaomi.feeder.pi2001 — feeder v3; repeated status properties have distinct comments; inaccessible and one-shot feeding fields must not become readable controls or Matter switches.

The household report received 2026-11-06 confirms all six deployed URNs and firmware versions; see `docs/household-followup-diagnostics.md`. The original dehumidifier projection remains v2, while the deployed device uses v1: `xiaomi.derh.13l.v1.json` separately preserves only its confirmed cached temperature declaration. `household-readings-2026-11-06.json` transcribes the sanitized report, not original network packets. Vendor feeder fields 5.3/5.4/5.6 have confirmed bool/read metadata but their values remain pending. No writes have been verified. A fixture using enum label `null` does not authorize replacing an actual JSON null with a healthy value.

The second household report is transcribed in `household-followup-readings-2026-11-06.json`: all nine tested curtain reads failed with -4004, with matching configured/handshake DIDs; feeder 5.3/5.4/5.6 returned JSON number 0 despite the bool declaration. Their names/types/access were cross-checked against the household cache metadata and public v3 specification projection. Numeric values remain raw conflicts. This adds no production coercion or protocol fallback. The feeder action projection uses input 2.8 as documented by Xiaomi's official integration wiki; feeding remains unsupported.

A subsequent user observation reports that all six curtains stay online in Mi Home, respond to the physical remote and report changed state, but do not respond to Mi Home controls. It is tracked separately from the protocol fixture. Further device probes are paused pending the result after fully exiting MijiaLAN. Neither the symptom nor the read-only test establishes the cause.
