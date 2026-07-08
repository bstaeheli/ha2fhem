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
from homeassistant.core import CoreState, HomeAssistant

from .commands import CommandHandler
from .const import CONF_EXCLUDE_DEVICES, CONF_INCLUDE_DEVICES, CONF_TOPIC_PREFIX, DOMAIN
from .contract import status_topic
from .publisher import Publisher

PLATFORMS: list[str] = []


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

    # Options flow save -> reload the entry so the new topic_prefix/filters take
    # effect immediately (publisher republishes discovery on start).
    # ponytail: reload republishes discovery for devices still in the filter,
    # but a device newly *excluded* keeps its old discovery entry in FHEM —
    # nothing ever publishes a delete for it (async_unload_entry only stops
    # state mirroring, see Publisher.async_stop). Ceiling: manual FHEM-side
    # cleanup (delete the reading) until a device is re-included or the FHEM
    # device is removed by hand. Upgrade path: diff old vs. new
    # include/exclude against the device registry and publish empty discovery
    # payloads for devices that dropped out — tracked as a follow-up issue.
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
