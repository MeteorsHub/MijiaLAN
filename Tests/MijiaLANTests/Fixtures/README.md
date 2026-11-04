# Reviewed specification projections

These fixtures are hand-reviewed projections of public specification pages, retrieved 2026-11-04. They are **not** raw device responses or complete official instance JSON. Device URNs/versions, service/property IDs, formats, access and the listed ranges/enums are preserved for the selected regression cases; unrelated services and some options are omitted. Property/service `type` fields use semantic short names, not invented full URNs. They are test resources only and do not replace the App’s cached schemas.

Sources:

- https://home.miot-spec.com/spec/dooya.motor.dc1545 — motor-controller v1; MIoT position 0=closed, 100=open; motor-control is write-only.
- https://home.miot-spec.com/spec/xiaomi.derh.13l — dehumidifier v2; environment temperature is float, step 1.
- https://home.miot-spec.com/spec/iot.tow_w.jd015 — towel-rack v1; surface temperature and setpoint are not room temperature.
- https://home.miot-spec.com/spec/giot.heater.v13daf — heater v1; heater and light are separate services; zero fault enum has placeholder label `null`.
- https://home.miot-spec.com/spec/xiaomi.pet_waterer.70m2 — fountain v2; two distinct out-water-interval properties at 2.7/2.11.
- https://home.miot-spec.com/spec/xiaomi.feeder.pi2001 — feeder v3; repeated status properties have distinct comments; inaccessible and one-shot feeding fields must not become readable controls or Matter switches.

Only the curtain's cached v1 URN has been confirmed on the user's Mac so far. Other fixtures do not establish the deployed firmware/specification version. Protocol return codes, raw values and successful real control remain pending household diagnostics. A fixture using enum label `null` does not authorize replacing an actual JSON null with a healthy value.
