# Architecture decisions

Load-bearing decisions with their evidence, recorded so they don't get
re-litigated. Amend with a new dated entry, don't rewrite history.

## 2026-07: Own FHEM module instead of `MQTT2_DEVICE`

**Decision:** Project A is a custom parent/child FHEM module
(`HA2FHEM_BRIDGE` / `HA2FHEM_CLIENT`) with a per-device-class profile
registry. `MQTT2_DEVICE` is not used at all.

**Why:**

- FHEM's `bridgeRegexp` + autocreate never parses discovery JSON. It only
  routes topics to device instances and logs the raw payload. The whole FHEM
  MQTT ecosystem ignores `homeassistant/+/config` on purpose (via
  `ignoreRegexp`) and uses hand-made `attrTemplate`s on native topics.
  "Device self-configures from discovery" is new code — nobody in FHEM does
  it today.
- We need full control of class→reading/set mapping, a clean child lifecycle
  (create on discovery, remove on empty payload), and bridge-level filters.
  With `MQTT2_DEVICE` that would mean `attrTemplate` sprawl and no lifecycle.

**How (verified mechanics):** `X_Define` stores its id in
`$modules{<TYPE>}{defptr}{<id>}` and calls `AssignIoPort($hash)`.
`X_Parse($io_hash, $msg)` fires from `Dispatch()` and matches via `defptr`.
Sending goes through `IOWrite($hash, "publish", "$topic $payload")`.
`MQTT2_CLIENT` dispatches only to `MQTT2_DEVICE` by default; our module hooks
in via the `clientOrder` attribute — no core patch. Direct precedent:
`10_MQTT_GENERIC_BRIDGE.pm`. Parent/child precedent: HUEBridge/HUEDevice.

**Structure:** modern ASC-style (`73_AutoShuttersControl.pm` /
`FHEM::Automation::ShuttersControl`): thin stubs in `FHEM/`, all logic as
Perl packages under `lib/FHEM/HA2FHEM/` (Bridge, Client, Discovery, Filter,
Profiles, Profiles/*), unit-testable without a running FHEM.

## 2026-07: Own HA custom integration instead of `mqtt_statestream`

**Decision:** Project B is a custom HA integration (`custom_components/ha2fhem`,
HACS-distributed) that re-exports HA's own devices as MQTT discovery, mirrors
state, and maps command topics to service calls.

**Why:**

- HA has no native "export own devices as discovery". `mqtt_statestream` is
  state-only: no command topics, no device grouping, not discovery format —
  useless for control.
- Real-world HA `value_template`s call runtime functions (`states(...)`,
  `is_state(...)`) that cannot be evaluated outside HA. There is no faithful
  Perl Jinja2 engine (`Text::Xslate`/TTerse is TT2, `Dotiac::DTL` is Django —
  only similar). Therefore the HA side **pre-renders** everything; the FHEM
  side never sees a template. Most trivial templates (`{{ value_json.x }}`)
  disappear into flat JSON handled by `json2nameValue`.

**How (verified building blocks):** manifest `dependencies: ["mqtt"]`;
`await mqtt.async_wait_for_mqtt_client(hass)` before subscribing;
`mqtt.async_publish` / `mqtt.async_subscribe`; enumerate via
`device_registry` / `entity_registry`; mirror via
`async_track_state_change_event`; commands via
`hass.services.async_call(domain, service, data)`; birth handling via
`homeassistant/status`.

## 2026-07: Packaging from day one

**Decision:** Distribution channels are set up with the first deployable code
(Phase 1), not at the end: `fhem/controls_ha2fhem.txt` for FHEM `update`,
`hacs.json` + tagged releases for HACS. No manual file copying onto real
installations, ever — the distribution channel is dogfooded from the first
version.
