"""Enumerate HA devices/entities and publish ha2fhem discovery + state.

Phase 1 is read-only: vacuum entities plus the sensor/binary_sensor entities
that live on the same HA device. All topic/payload construction goes through
contract.py so it stays byte-for-byte aligned with CONTRACT.md.
"""

from __future__ import annotations

import json
import logging
from typing import Callable

from homeassistant.components import mqtt
from homeassistant.core import Event, HomeAssistant, State, callback
from homeassistant.helpers import device_registry as dr
from homeassistant.helpers import entity_registry as er
from homeassistant.helpers.event import async_track_state_change_event

from .contract import (
    availability_topic,
    binary_sensor_payload,
    cover_command_topics_extra,
    cover_state_payload,
    discovery_payload,
    discovery_topic,
    entity_key,
    state_topic,
    vacuum_command_topics_extra,
    vacuum_state_payload,
)

_LOGGER = logging.getLogger(__name__)

SENSOR_DOMAINS = ("sensor", "binary_sensor")
MAIN_DOMAINS = ("vacuum", "cover")


def _matches_filter(value: str, filter_str: str) -> bool:
    items = {v.strip() for v in filter_str.split(",") if v.strip()}
    return value in items


def _device_allowed(
    device_id: str, device_name: str, include: str, exclude: str
) -> bool:
    if exclude and (_matches_filter(device_id, exclude) or _matches_filter(device_name, exclude)):
        return False
    if include and not (
        _matches_filter(device_id, include) or _matches_filter(device_name, include)
    ):
        return False
    return True


class Publisher:
    """Publishes discovery + mirrors state for the devices this config entry covers."""

    def __init__(
        self, hass: HomeAssistant, prefix: str, include_devices: str, exclude_devices: str
    ) -> None:
        self.hass = hass
        self.prefix = prefix
        self.include_devices = include_devices
        self.exclude_devices = exclude_devices
        self._unsubs: list[Callable[[], None]] = []

    async def async_start(self) -> None:
        """Publish discovery + availability for all selected devices, start mirroring."""
        device_reg = dr.async_get(self.hass)
        entity_reg = er.async_get(self.hass)

        main_entities = [
            entry
            for entry in entity_reg.entities.values()
            if entry.domain in MAIN_DOMAINS
        ]

        for main_entry in main_entities:
            if main_entry.device_id is None:
                continue
            device = device_reg.async_get(main_entry.device_id)
            if device is None:
                continue

            device_id = main_entry.device_id
            device_name = device.name_by_user or device.name or device_id

            if not _device_allowed(
                device_id, device_name, self.include_devices, self.exclude_devices
            ):
                continue

            await self._publish_availability(device_id)
            key = await self._publish_entity_discovery(
                main_entry, device_id, device_name, is_main=True
            )
            await self._start_entity(main_entry.entity_id, device_id, key, is_main=True)

            for other_entry in entity_reg.entities.values():
                if other_entry.device_id != device_id:
                    continue
                if other_entry.domain not in SENSOR_DOMAINS:
                    continue
                key = await self._publish_entity_discovery(
                    other_entry, device_id, device_name, is_main=False
                )
                await self._start_entity(other_entry.entity_id, device_id, key, is_main=False)

    async def async_stop(self) -> None:
        """Unsubscribe all state-change listeners."""
        for unsub in self._unsubs:
            unsub()
        self._unsubs.clear()

    async def _publish_entity_discovery(
        self, entry: er.RegistryEntry, device_id: str, device_name: str, is_main: bool
    ) -> str:
        _, object_id = entry.entity_id.split(".", 1)
        key = entity_key(
            entry.domain,
            object_id,
            is_main,
            translation_key=entry.translation_key,
            device_class=entry.device_class or entry.original_device_class,
            device_name=device_name,
        )
        entity_name = entry.name or entry.original_name or object_id

        extra = None
        if is_main:
            extra = {"schema": "state"}
            if entry.domain == "vacuum":
                state = self.hass.states.get(entry.entity_id)
                attributes = state.attributes if state is not None else {}
                supported_features = attributes.get("supported_features") or 0
                fan_speed_list = attributes.get("fan_speed_list") or []
                extra.update(
                    vacuum_command_topics_extra(
                        self.prefix, device_id, key, supported_features, fan_speed_list
                    )
                )
            elif entry.domain == "cover":
                state = self.hass.states.get(entry.entity_id)
                attributes = state.attributes if state is not None else {}
                supported_features = attributes.get("supported_features") or 0
                extra.update(
                    cover_command_topics_extra(
                        self.prefix, device_id, key, supported_features
                    )
                )

        payload = discovery_payload(
            self.prefix,
            entry.domain,
            device_id,
            key,
            device_name,
            entity_name,
            extra=extra,
        )
        topic = discovery_topic(self.prefix, entry.domain, device_id, key)
        await mqtt.async_publish(self.hass, topic, _dumps(payload), qos=0, retain=False)
        return key

    async def _publish_availability(self, device_id: str) -> None:
        await mqtt.async_publish(
            self.hass, availability_topic(self.prefix, device_id), "online", qos=0, retain=False
        )

    async def _start_entity(
        self, entity_id: str, device_id: str, key: str, is_main: bool
    ) -> None:
        """Subscribe to state changes and mirror the current state once.

        Without the initial dump, FHEM readings stay empty until the entity
        happens to change — for slow-moving stats that can be hours.
        """
        self._subscribe_state(entity_id, device_id, key, is_main)
        state = self.hass.states.get(entity_id)
        if state is not None:
            await self._publish_state(entity_id, device_id, key, is_main, state)

    def _subscribe_state(
        self, entity_id: str, device_id: str, key: str, is_main: bool
    ) -> None:
        @callback
        def _handle(event: Event) -> None:
            new_state: State | None = event.data.get("new_state")
            if new_state is None:
                return
            self.hass.async_create_task(
                self._publish_state(entity_id, device_id, key, is_main, new_state)
            )

        self._unsubs.append(
            async_track_state_change_event(self.hass, [entity_id], _handle)
        )

    async def _publish_state(
        self, entity_id: str, device_id: str, key: str, is_main: bool, new_state: State
    ) -> None:
        domain, _ = entity_id.split(".", 1)
        topic = state_topic(self.prefix, device_id, key)

        if is_main and domain == "vacuum":
            try:
                payload = vacuum_state_payload(
                    state=new_state.state,
                    battery_level=new_state.attributes.get("battery_level"),
                    fan_speed=new_state.attributes.get("fan_speed"),
                )
            except ValueError:
                # unavailable/unknown is the robot being asleep, not a bug
                log = (
                    _LOGGER.debug
                    if new_state.state in ("unavailable", "unknown")
                    else _LOGGER.warning
                )
                log("ignoring unmappable vacuum state %r for %s", new_state.state, entity_id)
                return
            body = _dumps(payload)
        elif is_main and domain == "cover":
            try:
                payload = cover_state_payload(
                    state=new_state.state,
                    position=new_state.attributes.get("current_cover_position"),
                )
            except ValueError:
                # unavailable/unknown is the cover being asleep, not a bug
                log = (
                    _LOGGER.debug
                    if new_state.state in ("unavailable", "unknown")
                    else _LOGGER.warning
                )
                log("ignoring unmappable cover state %r for %s", new_state.state, entity_id)
                return
            body = _dumps(payload)
        elif domain == "binary_sensor":
            body = binary_sensor_payload(new_state.state)
        else:
            body = new_state.state

        await mqtt.async_publish(self.hass, topic, body, qos=0, retain=False)


def _dumps(payload: dict) -> str:
    return json.dumps(payload)
