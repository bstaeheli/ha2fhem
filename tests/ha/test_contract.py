"""Unit tests for custom_components/ha2fhem/contract.py.

Imports contract.py directly from its file path so this test suite never
touches `homeassistant` (which is not installed in this environment, and
which custom_components/ha2fhem/__init__.py imports). This also guards the
"no homeassistant import in contract.py" hard requirement: if contract.py
ever grew such an import, this import would start failing.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

_CONTRACT_PATH = (
    Path(__file__).resolve().parents[2]
    / "custom_components"
    / "ha2fhem"
    / "contract.py"
)

_spec = importlib.util.spec_from_file_location("ha2fhem_contract", _CONTRACT_PATH)
contract = importlib.util.module_from_spec(_spec)
sys.modules["ha2fhem_contract"] = contract
_spec.loader.exec_module(contract)

PREFIX = "ha2fhem"


# ---------------------------------------------------------------------------
# Topic builders
# ---------------------------------------------------------------------------


def test_status_topic():
    assert contract.status_topic(PREFIX) == "ha2fhem/status"


def test_discovery_topic():
    assert (
        contract.discovery_topic(PREFIX, "vacuum", "roomba1", "vacuum")
        == "ha2fhem/discovery/vacuum/roomba1_vacuum/config"
    )


def test_discovery_topic_device_id_with_underscores():
    # device_id containing underscores must stay intact (matches FHEM-side
    # parsing test in tests/fhem/discovery.t).
    assert (
        contract.discovery_topic(PREFIX, "vacuum", "my_bot_2", "vacuum")
        == "ha2fhem/discovery/vacuum/my_bot_2_vacuum/config"
    )


def test_state_topic():
    assert (
        contract.state_topic(PREFIX, "roomba1", "vacuum")
        == "ha2fhem/devices/roomba1/vacuum/state"
    )


def test_availability_topic():
    assert (
        contract.availability_topic(PREFIX, "roomba1")
        == "ha2fhem/devices/roomba1/availability"
    )


def test_custom_prefix():
    assert contract.status_topic("myprefix") == "myprefix/status"
    assert (
        contract.state_topic("myprefix", "roomba1", "vacuum")
        == "myprefix/devices/roomba1/vacuum/state"
    )


# ---------------------------------------------------------------------------
# entity_key
# ---------------------------------------------------------------------------


def test_entity_key_main_is_domain():
    assert contract.entity_key("vacuum", "roomba", True) == "vacuum"


def test_entity_key_non_main_is_slugified_object_id():
    assert contract.entity_key("sensor", "battery", False) == "battery"
    assert contract.entity_key("binary_sensor", "Bin Full", False) == "bin_full"
    assert contract.entity_key("sensor", "roomba1 Total Cleaning Time", False) == (
        "roomba1_total_cleaning_time"
    )


# ---------------------------------------------------------------------------
# discovery_payload
# ---------------------------------------------------------------------------


def test_discovery_payload_structure():
    payload = contract.discovery_payload(
        PREFIX, "vacuum", "roomba1", "vacuum", "Roomba", "Roomba"
    )
    assert payload["unique_id"] == "ha2fhem_roomba1_vacuum"
    assert payload["state_topic"] == "ha2fhem/devices/roomba1/vacuum/state"
    assert payload["availability_topic"] == "ha2fhem/devices/roomba1/availability"
    assert payload["device"] == {
        "identifiers": ["ha2fhem_roomba1"],
        "name": "Roomba",
    }
    assert payload["name"] == "Roomba"


def test_discovery_payload_merges_extra():
    payload = contract.discovery_payload(
        PREFIX,
        "vacuum",
        "roomba1",
        "vacuum",
        "Roomba",
        "Roomba",
        extra={"schema": "state", "fan_speed_list": ["min", "max"]},
    )
    assert payload["schema"] == "state"
    assert payload["fan_speed_list"] == ["min", "max"]
    # extra never clobbers the structural fields we computed
    assert payload["unique_id"] == "ha2fhem_roomba1_vacuum"


def test_discovery_payload_rejects_state_topic_under_discovery_prefix(monkeypatch):
    # Hard rule #2 in CONTRACT.md: state topics must never live under the
    # discovery prefix. With the current topic shapes ("devices/..." vs.
    # "discovery/...") no device_id/entity_key content can make one collide
    # with the other -- the literal segments diverge at the first
    # character ("d-e-v" vs "d-i-s"). The guard is still load-bearing
    # defense-in-depth if the topic shape ever changes, so exercise it here
    # by monkeypatching state_topic to return a colliding value.
    monkeypatch.setattr(
        contract, "state_topic", lambda prefix, device_id, key: f"{prefix}/discovery/oops"
    )
    with pytest.raises(ValueError, match="discovery prefix"):
        contract.discovery_payload(
            PREFIX, "vacuum", "roomba1", "vacuum", "Roomba", "Roomba"
        )


def test_state_topic_and_discovery_topic_never_collide_by_construction():
    # Documents *why* the hard-rule guard above can't be hit via the public
    # API today: "devices" and "discovery" diverge at their third
    # character, so no device_id/entity_key can bridge the gap.
    for device_id, key in [("", ""), ("a", "b"), ("../discovery", "x"), ("x", "../../y")]:
        st = contract.state_topic(PREFIX, device_id, key)
        assert not st.startswith(f"{PREFIX}/discovery/")


# ---------------------------------------------------------------------------
# vacuum_state_payload — cross-checked against the CONTRACT.md example:
# {"state": "docked", "battery_level": 82, "fan_speed": "max", "docked": true,
#  "charging": true}
# ---------------------------------------------------------------------------


def test_vacuum_state_payload_contract_example():
    payload = contract.vacuum_state_payload(
        state="docked",
        battery_level=82,
        fan_speed="max",
        docked=True,
        charging=True,
    )
    assert payload == {
        "state": "docked",
        "battery_level": 82,
        "fan_speed": "max",
        "docked": True,
        "charging": True,
    }


def test_vacuum_state_payload_omits_none_values():
    payload = contract.vacuum_state_payload(state="cleaning")
    assert payload == {"state": "cleaning"}
    assert "battery_level" not in payload
    assert "fan_speed" not in payload
    assert "docked" not in payload
    assert "charging" not in payload
    assert "error" not in payload


def test_vacuum_state_payload_error_state():
    payload = contract.vacuum_state_payload(state="error", error="stuck")
    assert payload == {"state": "error", "error": "stuck"}


@pytest.mark.parametrize(
    "state", ["cleaning", "docked", "idle", "paused", "returning", "error"]
)
def test_vacuum_state_payload_accepts_all_contract_states(state):
    payload = contract.vacuum_state_payload(state=state)
    assert payload["state"] == state


def test_vacuum_state_payload_rejects_invalid_state():
    with pytest.raises(ValueError, match="invalid vacuum state"):
        contract.vacuum_state_payload(state="charging")


def test_vacuum_state_payload_rejects_empty_state():
    with pytest.raises(ValueError):
        contract.vacuum_state_payload(state="")
