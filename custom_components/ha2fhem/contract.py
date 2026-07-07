"""ha2fhem MQTT contract — pure functions, no homeassistant imports.

This module is the single place where the HA side encodes the topic tree
and payload schemas defined in CONTRACT.md (repo root). Keep it free of any
``homeassistant`` import so it stays unit-testable standalone (see
tests/ha/test_contract.py) and so the FHEM side's expectations can be
cross-checked byte-for-byte without spinning up Home Assistant.
"""

from __future__ import annotations

import re

VACUUM_STATES = {"cleaning", "docked", "idle", "paused", "returning", "error"}


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


# ---------------------------------------------------------------------------
# Entity keys
# ---------------------------------------------------------------------------


def entity_key(domain: str, object_id: str, is_main: bool) -> str:
    """Derive the stable entity_key used in topics/unique_id.

    For the main (controllable) entity of a device, the entity_key is the
    component/domain name itself (e.g. ``vacuum``). For any other entity of
    the device (sensors, binary_sensors, ...), the entity_key is a slugified
    version of the HA object_id (the part of entity_id after the dot).
    """
    if is_main:
        return domain
    return _slugify(object_id)


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
