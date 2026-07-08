"""The ha2fhem integration.

Re-exports HA's vacuum devices (and their sensor/binary_sensor siblings) as
ha2fhem MQTT discovery, mirrors state, and handles HA MQTT birth
(``homeassistant/status`` -> ``online``) by republishing everything.
Also handles command topics: incoming ``set`` / ``set_fan_speed`` /
``send_command`` payloads are mapped to ``vacuum.*`` service calls (see
commands.py); the resulting state change flows back via the state mirror.
"""

from __future__ import annotations

from typing import Callable

from homeassistant.components import mqtt
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import EVENT_HOMEASSISTANT_STARTED
from homeassistant.core import CoreState, Event, HomeAssistant, callback
from homeassistant.helpers import entity_registry as er
from homeassistant.helpers.event import async_call_later

from .commands import CommandHandler
from .const import CONF_EXCLUDE_DEVICES, CONF_INCLUDE_DEVICES, CONF_TOPIC_PREFIX, DOMAIN
from .contract import status_topic
from .publisher import MAIN_DOMAINS, SENSOR_DOMAINS, Publisher

PLATFORMS: list[str] = []

# Domains the publisher actually walks/tracks; anything else changing in the
# entity registry can't affect what we publish, so it's not worth a resync.
_RELEVANT_DOMAINS = MAIN_DOMAINS + SENSOR_DOMAINS

# ponytail: fixed debounce instead of smarter batching/coalescing -- HA fires
# one entity_registry_updated event per entity, so adding/removing a device
# with several entities means several events; this just waits for the burst
# to go quiet before resyncing once.
_RESYNC_DEBOUNCE_SECONDS = 5


async def _async_update_listener(hass: HomeAssistant, entry: ConfigEntry) -> None:
    """Options changed: reload the entry to pick up the new config."""
    await hass.config_entries.async_reload(entry.entry_id)


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Set up ha2fhem from a config entry."""
    await mqtt.async_wait_for_mqtt_client(hass)

    prefix = entry.options.get(CONF_TOPIC_PREFIX, entry.data.get(CONF_TOPIC_PREFIX, "ha2fhem"))
    include_devices = entry.options.get(
        CONF_INCLUDE_DEVICES, entry.data.get(CONF_INCLUDE_DEVICES, "")
    )
    exclude_devices = entry.options.get(
        CONF_EXCLUDE_DEVICES, entry.data.get(CONF_EXCLUDE_DEVICES, "")
    )

    publisher = Publisher(hass, prefix, include_devices, exclude_devices)
    command_handler = CommandHandler(hass, prefix, include_devices, exclude_devices)

    unsubs: list[Callable[[], None]] = []

    async def _publish_all() -> None:
        await publisher.async_stop()
        await publisher.async_start()

    async def _on_ha_status(msg) -> None:
        if msg.payload == "online":
            await _publish_all()

    await mqtt.async_publish(hass, status_topic(prefix), "online", qos=0, retain=False)

    # At HA boot other integrations (the actual vacuums) aren't ready yet —
    # publishing then mirrors empty attributes (no supported_features, no
    # states). Wait for STARTED; on entry reload hass is already running.
    if hass.state is CoreState.running:
        await _publish_all()
    else:
        async def _on_started(_event) -> None:
            await _publish_all()

        hass.bus.async_listen_once(EVENT_HOMEASSISTANT_STARTED, _on_started)

    await command_handler.async_start()

    unsub_status = await mqtt.async_subscribe(hass, "homeassistant/status", _on_ha_status, qos=0)
    unsubs.append(unsub_status)

    # Runtime device/entity add or remove (#15): re-run the publisher's full
    # sync, which both publishes discovery for anything new and (via
    # Publisher._publish_dropped, #23) sends an empty discovery payload for
    # anything that disappeared. entity_registry_updated is what actually
    # fires per added/removed entity; device_registry_updated does not carry
    # enough to know which discovery topics are affected, and the publisher
    # walks the entity registry anyway. One entity registry event per entity
    # means adding/removing a multi-entity device fires several events in a
    # burst, hence the debounce.
    _debounce_cancel: list[Callable[[], None] | None] = [None]

    def _cancel_pending_resync() -> None:
        if _debounce_cancel[0] is not None:
            _debounce_cancel[0]()
            _debounce_cancel[0] = None

    @callback
    def _on_entity_registry_updated(event: Event) -> None:
        # Registry loads while HA is still starting up shouldn't trigger a
        # publish; _on_started (or the CoreState.running branch above)
        # already covers the initial sync once HA is actually ready.
        if hass.state is not CoreState.running:
            return
        if event.data.get("action") not in ("create", "remove"):
            return
        entity_id = event.data.get("entity_id") or ""
        if entity_id.split(".", 1)[0] not in _RELEVANT_DOMAINS:
            return

        _cancel_pending_resync()

        @callback
        def _fire(_now) -> None:
            _debounce_cancel[0] = None
            hass.async_create_task(_publish_all())

        _debounce_cancel[0] = async_call_later(hass, _RESYNC_DEBOUNCE_SECONDS, _fire)

    unsubs.append(hass.bus.async_listen(er.EVENT_ENTITY_REGISTRY_UPDATED, _on_entity_registry_updated))
    unsubs.append(_cancel_pending_resync)

    # Options flow save -> reload the entry so the new topic_prefix/filters
    # take effect immediately; the publisher republishes discovery for
    # devices still in the filter and (#23, Publisher._publish_dropped)
    # sends an empty discovery payload for devices/entities that dropped out.
    entry.async_on_unload(entry.add_update_listener(_async_update_listener))

    hass.data.setdefault(DOMAIN, {})
    hass.data[DOMAIN][entry.entry_id] = {
        "publisher": publisher,
        "command_handler": command_handler,
        "prefix": prefix,
        "unsubs": unsubs,
    }

    return True


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Unload a config entry: publish offline, stop mirroring, clean up subscriptions."""
    data = hass.data.get(DOMAIN, {}).pop(entry.entry_id, None)
    if data is None:
        return True

    for unsub in data["unsubs"]:
        unsub()

    await data["command_handler"].async_stop()
    await data["publisher"].async_stop()

    await mqtt.async_publish(
        hass, status_topic(data["prefix"]), "offline", qos=0, retain=False
    )

    return True
