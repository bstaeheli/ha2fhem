# ha2fhem MQTT Contract

Single source of truth for topics and payload schemas. Both sides (FHEM module,
HA integration) validate against this document and its example payloads.

**Any change to this file gets its own reviewed commit. Never silent drift.**

Version: 0.1.0 (draft — Phase 0)

## Topic tree

The topic prefix is configurable on both sides; default is `ha2fhem`.
Everything below the prefix is fixed.

```
ha2fhem/status                                    -> "online" / "offline"   (bridge LWT)
ha2fhem/discovery/<component>/<object_id>/config  -> HA discovery JSON (self-describing)
ha2fhem/devices/<device_id>/<entity_key>/state    -> per-entity state (pre-rendered JSON)
ha2fhem/devices/<device_id>/<entity_key>/set      -> command (FHEM publishes here)
ha2fhem/devices/<device_id>/availability          -> "online" / "offline" per device
```

- `<component>`: HA MQTT component type (`vacuum`, `cover`, `switch`, `light`,
  `sensor`, `binary_sensor`, ...).
- `<device_id>`: stable, deterministic identifier derived from the HA device
  registry `device_id`.
- `<entity_key>`: stable, English key for the entity within the device
  (e.g. `vacuum`, `battery`, `bin_full`). For the main (controllable) entity
  it is the component name itself. For all other entities it is derived, in
  order of preference: the entity's `translation_key`, else its device class,
  else the `entity_id` object part with a leading device-name prefix stripped.
  Never the localized friendly name — entity keys (and thus FHEM reading
  names) must not change with the HA UI language.
- `<object_id>`: `<device_id>_<entity_key>`.

## Hard rules

Breaking any of these makes the project fail quietly:

1. **State payloads are pre-rendered.** The HA side evaluates all templates
   (including anything calling `states(...)` / `is_state(...)`) before
   publishing. The FHEM side never needs Jinja2. Payloads are flat (max one
   level) JSON so FHEM's `json2nameValue($EVENT)` expands them directly — or a
   single plain value per topic.
2. **State topics must NOT start with the discovery prefix**
   (`ha2fhem/discovery/`).
3. **Command payloads follow the HA MQTT platform schema** for the component,
   so the HA side maps them straight to service calls.
4. **`unique_id` and `device.identifiers` are stable and deterministic**,
   derived from the HA `device_id` / `entity_id`. FHEM devices survive
   restarts of either side.
5. **Discovery is republished on birth.** The HA side subscribes to
   `homeassistant/status` and republishes discovery + state on `online`.
   Retained discovery, if used at all, requires a cleanup routine. Never
   fire-and-forget. An **empty payload on a discovery topic deletes** the
   device (ghost prevention).
6. **One HA device → one FHEM child.** The child aggregates all entities of
   the device as readings; the controllable entity supplies the setters.
7. **Echo protection is the consumer's duty:** FHEM sets `ignoreRegexp` on its
   `MQTT2_CLIENT` for its own command topics.

## Discovery payload

Standard HA MQTT discovery JSON (long form, no abbreviations), one config per
entity, grouped by shared `device.identifiers`.

Required fields per config:

| Field | Rule |
|-------|------|
| `unique_id` | `ha2fhem_<device_id>_<entity_key>` |
| `device.identifiers` | `["ha2fhem_<device_id>"]` |
| `device.name` | HA device name |
| `state_topic` | per topic tree above |
| `availability_topic` | `ha2fhem/devices/<device_id>/availability` |
| command topics | only for controllable components, per component schema below |

## Component: `vacuum` (first device class — Roomba)

Follows the HA `vacuum.mqtt` **state schema** (modern; legacy is deprecated).

### State

Topic: `ha2fhem/devices/<device_id>/vacuum/state` — JSON dict:

| Key | Required | Values |
|-----|----------|--------|
| `state` | yes | `cleaning` / `docked` / `idle` / `paused` / `returning` / `error` |
| `battery_level` | no | 0–100 |
| `fan_speed` | no | one of `fan_speed_list` |
| `docked` | no | `true` / `false` |
| `charging` | no | `true` / `false` |
| `error` | no | error text |
| `segments` | no | segment map (required for `clean_segments`) |

Example:

```json
{"state": "docked", "battery_level": 82, "fan_speed": "max", "docked": true, "charging": true}
```

### Commands

Topic: `ha2fhem/devices/<device_id>/vacuum/set` — plain payloads:

| Payload | HA service call |
|---------|-----------------|
| `start` | `vacuum.start` |
| `stop` | `vacuum.stop` |
| `pause` | `vacuum.pause` |
| `return_to_base` | `vacuum.return_to_base` |
| `locate` | `vacuum.locate` |
| `clean_spot` | `vacuum.clean_spot` |

Fan speed on `ha2fhem/devices/<device_id>/vacuum/set_fan_speed`: one value from
`fan_speed_list` (e.g. `min` / `medium` / `high` / `max`) →
`vacuum.set_fan_speed`.

Send command on `ha2fhem/devices/<device_id>/vacuum/send_command`: free string,
or JSON `{"command": "<cmd>", "<param-key>": "<param-value>"}` when parameters
are given → `vacuum.send_command`.

`supported_features` in the discovery config is a subset of
`start, stop, pause, return_home, status, locate, clean_spot, fan_speed,
send_command` and drives which setters the FHEM profile exposes.

### Additional device entities

Sensors of the same HA device (Battery, Bin full, mission stats, cleaning
time, cleaned area m², ...) each publish on their own state topic
`ha2fhem/devices/<device_id>/<entity_key>/state` (plain value or flat JSON)
and appear as readings on the same FHEM child.

`binary_sensor` states are published as `true` / `false` (HA's `on` / `off`
mapped by the HA side); any other state (`unknown`, ...) passes through
unchanged.

## Example payloads

Machine-readable examples for both sides' tests live in `tests/payloads/`
(added with the first test suite; the examples above are normative until then).
