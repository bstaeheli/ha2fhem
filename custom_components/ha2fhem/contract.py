"""ha2fhem MQTT contract — pure functions, no homeassistant imports.

This module is the single place where the HA side encodes the topic tree
and payload schemas defined in CONTRACT.md (repo root). Keep it free of any
``homeassistant`` import so it stays unit-testable standalone (see
tests/ha/test_contract.py) and so the FHEM side's expectations can be
cross-checked byte-for-byte without spinning up Home Assistant.
"""

from __future__ import annotations

import json
import re

VACUUM_STATES = {"cleaning", "docked", "idle", "paused", "returning", "error"}

# CONTRACT.md "Component: cover" > State
COVER_STATES = {"open", "opening", "closed", "closing", "stopped"}

# Command topic kinds, i.e. the last segment of a command topic
# (`<prefix>/devices/<device_id>/<entity_key>/<kind>`).
COMMAND_KINDS = {"set", "set_fan_speed", "send_command", "set_position"}

# Plain payloads on the `set` command topic that map 1:1 to a same-named
# `vacuum.<payload>` service call (CONTRACT.md "Component: vacuum" > Commands).
VACUUM_SIMPLE_COMMANDS = {
    "start",
    "stop",
    "pause",
    "return_to_base",
    "locate",
    "clean_spot",
}


def _slugify(value: str) -> str:
    """Lowercase, replace anything not [a-z0-9_] with '_', collapse repeats."""
    value = value.strip().lower()
    value = re.sub(r"[^a-z0-9_]+", "_", value)
    value = re.sub(r"_+", "_", value)
    return value.strip("_")


# ---------------------------------------------------------------------------
# Topics
# ---------------------------------------------------------------------------


def status_topic(prefix: str) -> str:
    """Bridge-wide status topic: ``<prefix>/status``."""
    return f"{prefix}/status"


def discovery_topic(prefix: str, component: str, device_id: str, entity_key: str) -> str:
    """Discovery config topic.

    ``<prefix>/discovery/<component>/<device_id>_<entity_key>/config``
    """
    return f"{prefix}/discovery/{component}/{device_id}_{entity_key}/config"


def state_topic(prefix: str, device_id: str, entity_key: str) -> str:
    """Per-entity state topic: ``<prefix>/devices/<device_id>/<entity_key>/state``."""
    return f"{prefix}/devices/{device_id}/{entity_key}/state"


def availability_topic(prefix: str, device_id: str) -> str:
    """Per-device availability topic: ``<prefix>/devices/<device_id>/availability``."""
    return f"{prefix}/devices/{device_id}/availability"


def command_topic(prefix: str, device_id: str, entity_key: str, kind: str = "set") -> str:
    """Command topic: ``<prefix>/devices/<device_id>/<entity_key>/<kind>``.

    ``kind`` is one of :data:`COMMAND_KINDS` (``set``, ``set_fan_speed``,
    ``send_command``).
    """
    return f"{prefix}/devices/{device_id}/{entity_key}/{kind}"


def parse_command_topic(prefix: str, topic: str) -> tuple[str, str, str] | None:
    """Parse an incoming command topic into ``(device_id, entity_key, kind)``.

    Returns None if ``topic`` is not a command topic under ``prefix`` (wrong
    prefix, wrong shape, or an unknown trailing segment).
    """
    base = f"{prefix}/devices/"
    if not topic.startswith(base):
        return None

    parts = topic[len(base) :].split("/")
    if len(parts) != 3:
        return None

    device_id, entity_key, kind = parts
    if not device_id or not entity_key or kind not in COMMAND_KINDS:
        return None

    return device_id, entity_key, kind


# ---------------------------------------------------------------------------
# Entity keys
# ---------------------------------------------------------------------------


def entity_key(
    domain: str,
    object_id: str,
    is_main: bool,
    translation_key: str | None = None,
    device_class: str | None = None,
    device_name: str | None = None,
) -> str:
    """Derive the stable, English entity_key used in topics/unique_id.

    For the main (controllable) entity of a device, the entity_key is the
    component/domain name itself (e.g. ``vacuum``). For any other entity,
    per CONTRACT.md, in order of preference: the entity's ``translation_key``
    (stable English, e.g. ``bin_full``), else its device class (e.g.
    ``battery``), else the slugified object_id with a leading device-name
    prefix stripped. Never the localized friendly name.
    """
    if is_main:
        return domain
    # ponytail: no per-device collision dedupe; two entities of one device
    # sharing a device_class (and lacking translation_key) would share a key.
    if translation_key:
        return _slugify(translation_key)
    if device_class:
        return _slugify(device_class)
    key = _slugify(object_id)
    if device_name:
        prefix = _slugify(device_name) + "_"
        if key.startswith(prefix) and len(key) > len(prefix):
            key = key[len(prefix) :]
    return key


def binary_sensor_payload(state: str) -> str:
    """Map HA binary_sensor states to the contract's true/false.

    Anything else (``unknown``, ...) passes through unchanged.
    """
    return {"on": "true", "off": "false"}.get(state, state)


# ---------------------------------------------------------------------------
# Discovery payload
# ---------------------------------------------------------------------------


def discovery_payload(
    prefix: str,
    component: str,
    device_id: str,
    entity_key: str,
    device_name: str,
    entity_name: str,
    extra: dict | None = None,
) -> dict:
    """Build a standard HA MQTT discovery JSON payload (long form).

    Raises ValueError if the resulting state_topic would itself live under
    the discovery prefix (CONTRACT.md hard rule #2).
    """
    topic = state_topic(prefix, device_id, entity_key)
    discovery_prefix = f"{prefix}/discovery/"
    if topic.startswith(discovery_prefix):
        raise ValueError(
            f"state_topic {topic!r} must not start with the discovery prefix "
            f"{discovery_prefix!r}"
        )

    payload = {
        "unique_id": f"ha2fhem_{device_id}_{entity_key}",
        "name": entity_name,
        "state_topic": topic,
        "availability_topic": availability_topic(prefix, device_id),
        "device": {
            "identifiers": [f"ha2fhem_{device_id}"],
            "name": device_name,
        },
    }
    if extra:
        payload.update(extra)
    return payload


# ---------------------------------------------------------------------------
# Vacuum state payload (CONTRACT.md "Component: vacuum")
# ---------------------------------------------------------------------------


def vacuum_state_payload(
    state: str,
    battery_level: int | None = None,
    fan_speed: str | None = None,
    docked: bool | None = None,
    charging: bool | None = None,
    error: str | None = None,
) -> dict:
    """Build the flat vacuum state JSON per CONTRACT.md.

    Example: {"state": "docked", "battery_level": 82, "fan_speed": "max",
    "docked": true, "charging": true}
    """
    if state not in VACUUM_STATES:
        raise ValueError(
            f"invalid vacuum state {state!r}, must be one of {sorted(VACUUM_STATES)}"
        )

    payload: dict = {"state": state}
    if battery_level is not None:
        payload["battery_level"] = battery_level
    if fan_speed is not None:
        payload["fan_speed"] = fan_speed
    if docked is not None:
        payload["docked"] = docked
    if charging is not None:
        payload["charging"] = charging
    if error is not None:
        payload["error"] = error
    return payload


# ---------------------------------------------------------------------------
# Cover state payload (CONTRACT.md "Component: cover")
# ---------------------------------------------------------------------------


def cover_state_payload(state: str, position: int | None = None) -> dict:
    """Build the flat cover state JSON per CONTRACT.md.

    Example: {"state": "open", "position": 75}
    """
    if state not in COVER_STATES:
        raise ValueError(
            f"invalid cover state {state!r}, must be one of {sorted(COVER_STATES)}"
        )

    payload: dict = {"state": state}
    if position is not None:
        payload["position"] = position
    return payload


# ---------------------------------------------------------------------------
# Vacuum supported_features (CONTRACT.md "Component: vacuum" > supported_features)
#
# Bit values match homeassistant.components.vacuum.VacuumEntityFeature. Kept
# as plain constants here (not imported from homeassistant) so this module
# stays free of any ``homeassistant`` import.
# ---------------------------------------------------------------------------

VACUUM_FEATURE_TURN_ON = 1
VACUUM_FEATURE_TURN_OFF = 2
VACUUM_FEATURE_PAUSE = 4
VACUUM_FEATURE_STOP = 8
VACUUM_FEATURE_RETURN_HOME = 16
VACUUM_FEATURE_FAN_SPEED = 32
VACUUM_FEATURE_BATTERY = 64
VACUUM_FEATURE_STATUS = 128
VACUUM_FEATURE_SEND_COMMAND = 256
VACUUM_FEATURE_LOCATE = 512
VACUUM_FEATURE_CLEAN_SPOT = 1024
VACUUM_FEATURE_MAP = 2048
VACUUM_FEATURE_STATE = 4096
VACUUM_FEATURE_START = 8192

# Maps a VacuumEntityFeature bit to the contract feature name it drives.
# TURN_ON/TURN_OFF/BATTERY/MAP have no FHEM-side setter to gate and are
# deliberately left out; STATUS and STATE both collapse to "status".
_VACUUM_FEATURE_BITS = {
    VACUUM_FEATURE_START: "start",
    VACUUM_FEATURE_STOP: "stop",
    VACUUM_FEATURE_PAUSE: "pause",
    VACUUM_FEATURE_RETURN_HOME: "return_home",
    VACUUM_FEATURE_LOCATE: "locate",
    VACUUM_FEATURE_CLEAN_SPOT: "clean_spot",
    VACUUM_FEATURE_FAN_SPEED: "fan_speed",
    VACUUM_FEATURE_SEND_COMMAND: "send_command",
    VACUUM_FEATURE_STATUS: "status",
    VACUUM_FEATURE_STATE: "status",
}


def vacuum_features(supported_features: int) -> list[str]:
    """Decode a HA vacuum ``supported_features`` bitmask into contract names.

    Returns the sorted, de-duplicated subset of CONTRACT.md's ``start, stop,
    pause, return_home, status, locate, clean_spot, fan_speed, send_command``
    that the bitmask sets.
    """
    return sorted(
        {name for bit, name in _VACUUM_FEATURE_BITS.items() if supported_features & bit}
    )


def vacuum_command_topics_extra(
    prefix: str,
    device_id: str,
    entity_key: str,
    supported_features: int,
    fan_speed_list: list[str] | None = None,
) -> dict:
    """Build the discovery ``extra`` fields for the controllable vacuum entity.

    Adds the three command topics and ``supported_features`` (as contract
    feature names, CONTRACT.md "Component: vacuum" > Commands). ``fan_speed_list``
    is only included when the ``fan_speed`` feature is present. A bitmask of 0
    means "unknown" (entity unavailable, e.g. at HA startup) — per CONTRACT.md
    the key is then omitted so the FHEM side exposes all setters, not none.
    """
    extra = {
        "command_topic": command_topic(prefix, device_id, entity_key, "set"),
        "set_fan_speed_topic": command_topic(prefix, device_id, entity_key, "set_fan_speed"),
        "send_command_topic": command_topic(prefix, device_id, entity_key, "send_command"),
    }
    if supported_features:
        features = vacuum_features(supported_features)
        extra["supported_features"] = features
        if "fan_speed" in features:
            extra["fan_speed_list"] = list(fan_speed_list or [])
    return extra


# ---------------------------------------------------------------------------
# Cover supported_features (CONTRACT.md "Component: cover" > supported_features)
#
# Bit values match homeassistant.components.cover.CoverEntityFeature. Kept as
# plain constants here (not imported from homeassistant) so this module stays
# free of any ``homeassistant`` import.
# ---------------------------------------------------------------------------

COVER_FEATURE_OPEN = 1
COVER_FEATURE_CLOSE = 2
COVER_FEATURE_SET_POSITION = 4
COVER_FEATURE_STOP = 8

_COVER_FEATURE_BITS = {
    COVER_FEATURE_OPEN: "open",
    COVER_FEATURE_CLOSE: "close",
    COVER_FEATURE_SET_POSITION: "set_position",
    COVER_FEATURE_STOP: "stop",
}


def cover_features(supported_features: int) -> list[str]:
    """Decode a HA cover ``supported_features`` bitmask into contract names.

    Returns the sorted, de-duplicated subset of CONTRACT.md's ``open, close,
    set_position, stop`` that the bitmask sets.
    """
    return sorted(
        {name for bit, name in _COVER_FEATURE_BITS.items() if supported_features & bit}
    )


def cover_command_topics_extra(
    prefix: str, device_id: str, entity_key: str, supported_features: int
) -> dict:
    """Build the discovery ``extra`` fields for the controllable cover entity.

    Adds the two command topics and ``supported_features`` (as contract
    feature names, CONTRACT.md "Component: cover" > Commands). A bitmask of 0
    means "unknown" (entity unavailable, e.g. at HA startup) — per CONTRACT.md
    the key is then omitted so the FHEM side exposes all setters, not none.
    """
    extra = {
        "command_topic": command_topic(prefix, device_id, entity_key, "set"),
        "set_position_topic": command_topic(prefix, device_id, entity_key, "set_position"),
    }
    if supported_features:
        extra["supported_features"] = cover_features(supported_features)
    return extra


# ---------------------------------------------------------------------------
# Commands (CONTRACT.md "Component: vacuum" / "Component: cover" > Commands)
# ---------------------------------------------------------------------------


def command_to_service(component: str, topic_kind: str, payload: str) -> tuple[str, dict] | None:
    """Map an incoming command payload to a ``(service, service_data_extra)`` pair.

    ``component`` is the HA domain of the main entity (``vacuum`` or
    ``cover``). ``topic_kind`` is one of :data:`COMMAND_KINDS` (as returned by
    :func:`parse_command_topic`). ``service_data_extra`` never includes
    ``entity_id`` -- the caller adds that from the resolved entity. Returns
    None for anything that doesn't map to a valid service call (unknown
    payload, empty payload, unknown topic_kind/component combination); the
    caller should log and ignore.
    """
    if component == "vacuum":
        return _vacuum_command_to_service(topic_kind, payload)
    if component == "cover":
        return _cover_command_to_service(topic_kind, payload)
    return None


def _vacuum_command_to_service(topic_kind: str, payload: str) -> tuple[str, dict] | None:
    if topic_kind == "set":
        if payload in VACUUM_SIMPLE_COMMANDS:
            return payload, {}
        return None

    if topic_kind == "set_fan_speed":
        if not payload:
            return None
        return "set_fan_speed", {"fan_speed": payload}

    if topic_kind == "send_command":
        if not payload:
            return None

        try:
            data = json.loads(payload)
        except (json.JSONDecodeError, TypeError):
            data = None

        if isinstance(data, dict):
            command = data.get("command")
            if not command:
                return None
            params = {key: value for key, value in data.items() if key != "command"}
            extra = {"command": command}
            if params:
                extra["params"] = params
            return "send_command", extra

        return "send_command", {"command": payload}

    return None


# Plain payloads on the `set` command topic that map 1:1 to a cover service
# call (CONTRACT.md "Component: cover" > Commands).
COVER_SIMPLE_COMMANDS = {
    "OPEN": "open_cover",
    "CLOSE": "close_cover",
    "STOP": "stop_cover",
}


def _cover_command_to_service(topic_kind: str, payload: str) -> tuple[str, dict] | None:
    if topic_kind == "set":
        service = COVER_SIMPLE_COMMANDS.get(payload)
        return (service, {}) if service else None

    if topic_kind == "set_position":
        try:
            position = int(payload)
        except (TypeError, ValueError):
            return None
        if not 0 <= position <= 100:
            return None
        return "set_cover_position", {"position": position}

    return None
