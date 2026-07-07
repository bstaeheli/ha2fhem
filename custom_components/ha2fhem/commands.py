"""Command topics → vacuum service calls.

Subscribes to the three vacuum command topic patterns under the configured
prefix (``set``, ``set_fan_speed``, ``send_command``), resolves the incoming
``(device_id, entity_key)`` against the entity registry the same way
publisher.py does, and calls the matching ``vacuum.*`` service. All
topic/payload parsing goes through contract.py so it stays byte-for-byte
aligned with CONTRACT.md.
"""

from __future__ import annotations

import logging
from typing import Callable

from homeassistant.components import mqtt
from homeassistant.core import HomeAssistant
from homeassistant.helpers import device_registry as dr
from homeassistant.helpers import entity_registry as er

from .contract import COMMAND_KINDS, command_to_service, parse_command_topic
from .publisher import MAIN_DOMAINS, _device_allowed

_LOGGER = logging.getLogger(__name__)


class CommandHandler:
    """Subscribes to command topics and dispatches vacuum service calls."""

    def __init__(
        self, hass: HomeAssistant, prefix: str, include_devices: str, exclude_devices: str
    ) -> None:
        self.hass = hass
        self.prefix = prefix
        self.include_devices = include_devices
        self.exclude_devices = exclude_devices
        self._unsubs: list[Callable[[], None]] = []

    async def async_start(self) -> None:
        """Subscribe to the command topics for every kind in COMMAND_KINDS."""
        for kind in COMMAND_KINDS:
            topic = f"{self.prefix}/devices/+/+/{kind}"
            unsub = await mqtt.async_subscribe(self.hass, topic, self._handle_message, qos=0)
            self._unsubs.append(unsub)

    async def async_stop(self) -> None:
        """Unsubscribe from all command topics."""
        for unsub in self._unsubs:
            unsub()
        self._unsubs.clear()

    async def _handle_message(self, msg) -> None:
        parsed = parse_command_topic(self.prefix, msg.topic)
        if parsed is None:
            _LOGGER.debug("ignoring non-command topic %s", msg.topic)
            return
        device_id, entity_key, kind = parsed

        result = command_to_service(kind, msg.payload)
        if result is None:
            _LOGGER.warning(
                "ignoring invalid %s payload %r on %s", kind, msg.payload, msg.topic
            )
            return
        service, extra = result

        entity_id = self._resolve_entity_id(device_id, entity_key)
        if entity_id is None:
            _LOGGER.warning(
                "no vacuum entity for device_id=%s entity_key=%s (topic %s)",
                device_id,
                entity_key,
                msg.topic,
            )
            return

        await self.hass.services.async_call(
            "vacuum", service, {"entity_id": entity_id, **extra}, blocking=False
        )

    def _resolve_entity_id(self, device_id: str, entity_key: str) -> str | None:
        """Mirror publisher.py's registry walk to find the vacuum entity_id.

        The main (controllable) entity's entity_key is always its domain
        (see contract.entity_key), so for the vacuum component that's the
        fixed string "vacuum".
        """
        entity_reg = er.async_get(self.hass)
        device_reg = dr.async_get(self.hass)

        for entry in entity_reg.entities.values():
            if entry.device_id != device_id or entry.domain not in MAIN_DOMAINS:
                continue
            if entry.domain != entity_key:
                continue

            device = device_reg.async_get(entry.device_id)
            if device is None:
                continue
            device_name = device.name_by_user or device.name or entry.device_id
            if not _device_allowed(
                entry.device_id, device_name, self.include_devices, self.exclude_devices
            ):
                continue

            return entry.entity_id

        return None
