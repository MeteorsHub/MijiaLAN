# hass-xiaomi-miot (derived data)

[al-one/hass-xiaomi-miot](https://github.com/al-one/hass-xiaomi-miot) at `75bc74f67275bde6a8742b6638039819e10eaea5`, Apache 2.0 (`LICENSE`). No source code is vendored; upstream has no NOTICE file.

## What is used

`Sources/MijiaLAN/Resources/hass-xiaomi-miot-miio2miot.json` is converted from `custom_components/xiaomi_miot/core/miio2miot_specs.py`: the tables that map MIoT service and property IDs of legacy miIO devices to their `get_prop` names and `set_*` methods.

## Changes

`scripts/import_hass_xiaomi_miot.py` makes the conversion. It parses the Python file without running it and changes the data as follows:

- Jinja read and write templates become named transforms such as a ratio, offset, or value table. A template with no transform is left out, and the reason is recorded under `skipped`.
- Models whose state comes from commands rather than `get_prop` (`without_props`, `miio_commands`, `miio_template`) are left out for now.
- `extend_model` entries are merged into their model, and the base model is kept under `base`.

Hand-checked tables in `LegacyMiio.swift` take priority over the converted ones for the same model.
