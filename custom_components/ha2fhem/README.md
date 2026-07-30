# ha2fhem — Home Assistant side

Re-exports Home Assistant's own devices as `ha2fhem` MQTT discovery, mirrors
their state, and turns incoming commands from the [FHEM side](../../fhem/README.md)
into HA service calls. Templates are pre-rendered here, so FHEM never needs
Jinja2. Topic tree and payload schemas: [CONTRACT.md](../../CONTRACT.md).

## Requirements

- Home Assistant with the [MQTT integration](https://www.home-assistant.io/integrations/mqtt/)
  already set up and connected to a broker (ha2fhem depends on it and won't
  set up MQTT for you).
- [HACS](https://hacs.xyz/) installed.

## Install

1. HACS → the three-dot menu → **Custom repositories**.
2. Add `https://github.com/bstaeheli/ha2fhem`, category **Integration**.
3. Find **ha2fhem** in HACS and install it.
4. Restart Home Assistant.
5. **Settings → Devices & Services → Add Integration → ha2fhem.**

The GitHub repo is a read-only mirror kept only because HACS requires
GitHub; development and issues happen on
[Codeberg](https://codeberg.org/bstaeheli/ha2fhem).

## Configure

The setup form (and later **Settings → Devices & Services → ha2fhem →
Configure** to edit the same fields):

| Field | Meaning |
|---|---|
| MQTT topic prefix (`topic_prefix`) | Default `ha2fhem`. Must match `topicPrefix` on the FHEM bridge. |
| Include device classes (`include_domains`) | Multi-select over `vacuum`, `cover`, `switch`, `light`. Empty = all. |
| Exclude device classes (`exclude_domains`) | Same list; wins over include. |
| Include integrations (`include_integrations`) | Multi-select over the integrations installed on this HA (e.g. `roomba`, `overkiz`). Empty = all. |
| Exclude integrations (`exclude_integrations`) | Same list; wins over include. |
| Include devices (`include_devices`) | Comma-separated device ids or names to publish. Empty = all. |
| Exclude devices (`exclude_devices`) | Same syntax; wins over include. |

The three dimensions (device class, integration, device) are evaluated
against a device's main entity: any exclude match drops the device outright,
then every *non-empty* include list has to match. So include device classes
`cover` plus include integrations `overkiz` publishes exactly the Overkiz
covers.

Only a single instance is allowed per Home Assistant.

## What gets published

Devices from the domains `vacuum`, `cover`, `switch`, `light` are published
as the controllable ("main") entity of a device; their `sensor` and
`binary_sensor` siblings are attached to the same device as read-only
readings. Everything publishes with `retain=false` — a Home Assistant
restart or a reload of the config entry (e.g. after changing options)
re-announces discovery and state from scratch, so nothing depends on broker
retention.

Discovery is also republished whenever HA sees `homeassistant/status` go
`online`, and whenever a relevant device/entity is added or removed at
runtime.

## Troubleshooting

- **Entities missing on the FHEM side:** check the include/exclude filters
  above — a device excluded (or not matched by a non-empty include list on
  any of the three dimensions) never gets discovery published at all, so
  nothing to check on the FHEM side will help.
- **Vacuum shows unavailable / asleep:** normal. `unavailable` just mirrors
  the underlying HA entity's own availability (e.g. a Roomba that went to
  sleep) — it is not a bridge problem.
