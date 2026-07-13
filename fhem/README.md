# ha2fhem — FHEM side

Consumes `ha2fhem` MQTT discovery (published by the [HA integration](../custom_components/ha2fhem/README.md)
or, opt-in, by other discovery producers — see below) and creates one FHEM
device per Home Assistant device. Topic tree and payload schemas: [CONTRACT.md](../CONTRACT.md).

## Requirements

- A running FHEM install.
- An MQTT broker both FHEM and Home Assistant can reach.
- An `MQTT2_CLIENT` in FHEM connected to that broker (create one if you don't
  already have one — see below).

## Install

```
update all https://codeberg.org/bstaeheli/ha2fhem/raw/branch/main/fhem/controls_ha2fhem.txt
shutdown restart
```

This pulls `10_HA2FHEM_BRIDGE.pm`, `11_HA2FHEM_CLIENT.pm` and the
`FHEM::HA2FHEM::*` library modules. The restart is required — FHEM only
picks up new `.pm` files on load.

## Configure

### 1. MQTT2_CLIENT

Skip this if you already have one pointed at your broker:

```
define mqtt2 MQTT2_CLIENT <broker-host>:1883
```

If the broker needs credentials (`username` is an attribute, the password is
stored via `set`):

```
attr mqtt2 username <user>
set mqtt2 password <pass>
```

### 2. The bridge

```
define ha2fhem HA2FHEM_BRIDGE
```

The bridge picks up the `MQTT2_CLIENT` automatically if there's only one
(`IODev`, set explicitly with `attr ha2fhem IODev <name>` otherwise), and
registers itself at the front of that client's `clientOrder` so it sees
discovery/state traffic before `MQTT2_DEVICE` and friends.

### 3. Echo guard (mandatory)

The bridge publishes its own command topics (`.../set`, `.../set_fan_speed`,
`.../send_command`, `.../set_position`) through the same `MQTT2_CLIENT` it
listens on. Without an ignore rule those messages echo straight back in as
"state" and confuse the FHEM device. Set this on the `MQTT2_CLIENT`
(`mqtt2` in the examples above):

```
attr mqtt2 ignoreRegexp ^ha2fhem/devices/[^/]+/[^/]+/(set|set_fan_speed|send_command|set_position):
```

Adjust the `ha2fhem/` prefix if you changed `topicPrefix` (below). The regex
**must** be anchored with `^` — `MQTT2_CLIENT` matches `ignoreRegexp`
unanchored against the whole `topic:value` string, and an unanchored pattern
also matches inside discovery config JSON (which embeds the command topics as
values), silently eating your discovery messages. If you forget this, the
bridge logs a reminder with the exact line to add once it has an `IODev`.

## Attributes

Set on the bridge device (`ha2fhem` above):

| Attribute | Meaning |
|-----------|---------|
| `topicPrefix` | MQTT topic prefix. Default `ha2fhem`. Must match the HA side's `topic_prefix`. |
| `genericDiscoveryPrefix` | Opt-in: also consume plain HA MQTT discovery from other producers (zigbee2mqtt, Tasmota, ESPHome) under this prefix (e.g. `homeassistant`). Off by default. See the [coexistence section](../README.md#coexistence-with-mqtt2_device) in the root README before enabling this on a broker that already has `MQTT2_DEVICE`s. |
| `includeDevices` | Comma/space-separated HA device ids or names to allow. Empty = all. |
| `excludeDevices` | Same syntax; wins over `includeDevices`. |
| `includeClasses` | Comma/space-separated component names to allow as main (controllable) devices, e.g. `vacuum cover`. Empty = all. `sensor`/`binary_sensor` always follow their device regardless of this filter. |
| `disable` | `0`/`1`, standard FHEM disable. |

## What you get

One `HA2FHEM_CLIENT` device per Home Assistant device, auto-created in room
`HA2FHEM` as discovery arrives — nothing to `define` by hand. All of the
device's entities (main entity plus its sensors/binary_sensors) show up as
readings on that one device. Setters appear automatically, gated by the HA
side's `supported_features` (when unknown, e.g. right after startup, all
setters for the class are shown rather than none):

| Device class | Setters |
|---|---|
| `vacuum` | `start`, `stop`, `pause`, `return_to_base`, `dock`, `locate`, `clean_spot`, `fan_speed <value>`, `send_command <cmd>` |
| `cover` | `open`, `close`, `stop`, `pct` (slider 0–100) |
| `switch` | `on`, `off` |
| `light` | `on`, `off` (brightness is mirrored read-only, not yet settable) |

Example:

```
set ha2fhem_vacuum_livingroom start
set ha2fhem_shutters_kitchen pct 50
```

Supported device classes today: `vacuum`, `cover`, `switch`, `light`, plus
`sensor`/`binary_sensor` as read-only readings on whichever device they
belong to. Full topic/payload details: [CONTRACT.md](../CONTRACT.md).

## Troubleshooting

**No children appearing:**

- Check the echo guard is set and anchored (`^ha2fhem/...`, see above) —
  `list ha2fhem` shows the `peer` reading once the HA side has announced
  itself on `<prefix>/status`.
- Check `clientOrder` on the `MQTT2_CLIENT` actually lists `HA2FHEM_BRIDGE`
  (`attr mqtt2 clientOrder`) — the bridge registers itself on `define`, but
  only while FHEM already knows about the `MQTT2_CLIENT`.
- Check `topicPrefix` on the bridge matches `topic_prefix` configured on the
  HA integration side (both default to `ha2fhem`, but a mismatch here means
  the bridge never sees the discovery topics).
