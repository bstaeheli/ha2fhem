# ha2fhem

Use your Home Assistant devices in FHEM — bidirectional, device-grouped, over MQTT.

## What

Two components, usable together or alone, glued by a shared MQTT contract:

- **FHEM module `HA2FHEM`** (parent/child): consumes Home Assistant MQTT discovery and creates FHEM devices from it, driven by per-device-class profiles. Long-term it can consume *any* discovery producer (zigbee2mqtt, Tasmota, ESPHome) — not just our HA side.
- **HA custom integration `ha2fhem`** (HACS): re-exports Home Assistant's own devices as MQTT discovery, mirrors their state, and turns incoming commands into HA service calls. Templates are pre-rendered on the HA side, so FHEM never needs Jinja2.
- **`CONTRACT.md`**: the single source of truth for topics and payload schemas. Both sides test against it.

First supported device class: `vacuum` (iRobot Roomba via the HA `roomba` integration), full round trip — `set <vac> start` in FHEM makes the robot clean.

## Status

Early development. The roadmap lives in the [issues and milestones](https://codeberg.org/bstaeheli/ha2fhem/issues) — start with the pinned roadmap issue.

## Why not existing tools?

- FHEM's `MQTT2_DEVICE` + autocreate deliberately does not parse HA discovery JSON; the FHEM MQTT ecosystem relies on hand-made `attrTemplate`s instead.
- HA's `mqtt_statestream` is state-only: no command topics, no device grouping, not discovery format — useless for control.

So both sides are real builds. See the pinned roadmap issue for the architecture.

## GitHub mirror

Development happens here on Codeberg. The [GitHub mirror](https://github.com/bstaeheli/ha2fhem)
exists only because HACS requires GitHub — it is read-only and updated
manually (`tools/mirror-to-github.sh`; commit hashes differ, the Codeberg
repo uses git's SHA-256 object format which GitHub does not support).
Issues and pull requests: Codeberg only.

## Contributing

Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Issues and discussion in English preferred (German fine too).

## License

[GPL-2.0](LICENSE)
