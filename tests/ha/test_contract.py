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


def test_entity_key_prefers_translation_key():
    # localized object_id must not leak into the key when HA gives us a
    # stable English translation_key
    assert contract.entity_key(
        "binary_sensor", "eg_behalter_voll", False,
        translation_key="bin_full", device_class="occupancy", device_name="EG",
    ) == "bin_full"


def test_entity_key_falls_back_to_device_class():
    assert contract.entity_key(
        "sensor", "eg_batterie", False,
        translation_key=None, device_class="battery", device_name="EG",
    ) == "battery"


def test_entity_key_strips_device_name_prefix_from_object_id():
    assert contract.entity_key(
        "sensor", "eg_missionen_insgesamt", False, device_name="EG"
    ) == "missionen_insgesamt"
    # object_id that IS just the device name keeps its key
    assert contract.entity_key("sensor", "eg", False, device_name="EG") == "eg"
    # no device_name -> unchanged
    assert contract.entity_key("sensor", "eg_batterie", False) == "eg_batterie"


def test_entity_key_main_ignores_name_sources():
    assert contract.entity_key(
        "vacuum", "eg", True, translation_key="x", device_class="y", device_name="EG"
    ) == "vacuum"


def test_binary_sensor_payload_maps_on_off():
    assert contract.binary_sensor_payload("on") == "true"
    assert contract.binary_sensor_payload("off") == "false"
    assert contract.binary_sensor_payload("unknown") == "unknown"


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


# ---------------------------------------------------------------------------
# command_topic / parse_command_topic
# ---------------------------------------------------------------------------


def test_command_topic_default_kind_is_set():
    assert (
        contract.command_topic(PREFIX, "roomba1", "vacuum")
        == "ha2fhem/devices/roomba1/vacuum/set"
    )


def test_command_topic_explicit_kinds():
    assert (
        contract.command_topic(PREFIX, "roomba1", "vacuum", "set_fan_speed")
        == "ha2fhem/devices/roomba1/vacuum/set_fan_speed"
    )
    assert (
        contract.command_topic(PREFIX, "roomba1", "vacuum", "send_command")
        == "ha2fhem/devices/roomba1/vacuum/send_command"
    )


@pytest.mark.parametrize("kind", ["set", "set_fan_speed", "send_command"])
def test_parse_command_topic_all_kinds(kind):
    topic = f"ha2fhem/devices/roomba1/vacuum/{kind}"
    assert contract.parse_command_topic(PREFIX, topic) == ("roomba1", "vacuum", kind)


def test_parse_command_topic_custom_prefix():
    topic = "myprefix/devices/roomba1/vacuum/set"
    assert contract.parse_command_topic("myprefix", topic) == ("roomba1", "vacuum", "set")
    # Wrong prefix does not match.
    assert contract.parse_command_topic(PREFIX, topic) is None


def test_parse_command_topic_extracts_device_id_and_entity_key():
    topic = "ha2fhem/devices/my_bot_2/battery/set"
    assert contract.parse_command_topic(PREFIX, topic) == ("my_bot_2", "battery", "set")


@pytest.mark.parametrize(
    "topic",
    [
        "ha2fhem/devices/roomba1/vacuum/state",  # state topic, not a command
        "ha2fhem/devices/roomba1/vacuum/unknown_kind",
        "ha2fhem/devices/roomba1/vacuum",  # missing kind segment
        "ha2fhem/devices/roomba1/vacuum/set/extra",  # too many segments
        "ha2fhem/status",
        "ha2fhem/discovery/vacuum/roomba1_vacuum/config",
        "other/devices/roomba1/vacuum/set",  # wrong prefix
    ],
)
def test_parse_command_topic_rejects_non_command_topics(topic):
    assert contract.parse_command_topic(PREFIX, topic) is None


# ---------------------------------------------------------------------------
# command_to_service
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "payload", ["start", "stop", "pause", "return_to_base", "locate", "clean_spot"]
)
def test_command_to_service_simple_commands(payload):
    assert contract.command_to_service("vacuum", "set", payload) == (payload, {})


def test_command_to_service_unknown_set_payload_is_none():
    assert contract.command_to_service("vacuum", "set", "bogus") is None


def test_command_to_service_empty_set_payload_is_none():
    assert contract.command_to_service("vacuum", "set", "") is None


def test_command_to_service_fan_speed():
    assert contract.command_to_service("vacuum", "set_fan_speed", "max") == (
        "set_fan_speed",
        {"fan_speed": "max"},
    )


def test_command_to_service_fan_speed_empty_payload_is_none():
    assert contract.command_to_service("vacuum", "set_fan_speed", "") is None


def test_command_to_service_send_command_plain_string():
    assert contract.command_to_service("vacuum", "send_command", "clean_room") == (
        "send_command",
        {"command": "clean_room"},
    )


def test_command_to_service_send_command_json_with_params():
    payload = '{"command": "go_to", "x": 1, "y": 2}'
    assert contract.command_to_service("vacuum", "send_command", payload) == (
        "send_command",
        {"command": "go_to", "params": {"x": 1, "y": 2}},
    )


def test_command_to_service_send_command_json_without_extra_params():
    payload = '{"command": "clean_room"}'
    assert contract.command_to_service("vacuum", "send_command", payload) == (
        "send_command",
        {"command": "clean_room"},
    )


def test_command_to_service_send_command_json_missing_command_is_none():
    assert contract.command_to_service("vacuum", "send_command", '{"x": 1}') is None


def test_command_to_service_send_command_empty_payload_is_none():
    assert contract.command_to_service("vacuum", "send_command", "") is None


def test_command_to_service_unknown_topic_kind_is_none():
    assert contract.command_to_service("vacuum", "bogus_kind", "start") is None


# ---------------------------------------------------------------------------
# vacuum_features — bitmask -> contract feature names
# (homeassistant.components.vacuum.VacuumEntityFeature bit values)
# ---------------------------------------------------------------------------


def test_vacuum_features_zero_is_empty():
    assert contract.vacuum_features(0) == []


def test_vacuum_features_real_world_bitmask_13084():
    # Real-world example from a production install: START(8192) + STATE(4096)
    # + LOCATE(512) + SEND_COMMAND(256) + RETURN_HOME(16) + STOP(8) + PAUSE(4).
    # No FAN_SPEED(32) bit, no CLEAN_SPOT(1024) bit.
    assert contract.vacuum_features(13084) == [
        "locate",
        "pause",
        "return_home",
        "send_command",
        "start",
        "status",
        "stop",
    ]
    assert "fan_speed" not in contract.vacuum_features(13084)
    assert "clean_spot" not in contract.vacuum_features(13084)


def test_vacuum_features_full_mask_has_everything():
    full_mask = (
        contract.VACUUM_FEATURE_TURN_ON
        | contract.VACUUM_FEATURE_TURN_OFF
        | contract.VACUUM_FEATURE_PAUSE
        | contract.VACUUM_FEATURE_STOP
        | contract.VACUUM_FEATURE_RETURN_HOME
        | contract.VACUUM_FEATURE_FAN_SPEED
        | contract.VACUUM_FEATURE_BATTERY
        | contract.VACUUM_FEATURE_STATUS
        | contract.VACUUM_FEATURE_SEND_COMMAND
        | contract.VACUUM_FEATURE_LOCATE
        | contract.VACUUM_FEATURE_CLEAN_SPOT
        | contract.VACUUM_FEATURE_MAP
        | contract.VACUUM_FEATURE_STATE
        | contract.VACUUM_FEATURE_START
    )
    assert contract.vacuum_features(full_mask) == [
        "clean_spot",
        "fan_speed",
        "locate",
        "pause",
        "return_home",
        "send_command",
        "start",
        "status",
        "stop",
    ]


def test_vacuum_features_status_dedupes_status_and_state_bits():
    both = contract.VACUUM_FEATURE_STATUS | contract.VACUUM_FEATURE_STATE
    assert contract.vacuum_features(both) == ["status"]


def test_vacuum_features_ignores_turn_on_off_battery_map():
    ignored = (
        contract.VACUUM_FEATURE_TURN_ON
        | contract.VACUUM_FEATURE_TURN_OFF
        | contract.VACUUM_FEATURE_BATTERY
        | contract.VACUUM_FEATURE_MAP
    )
    assert contract.vacuum_features(ignored) == []


# ---------------------------------------------------------------------------
# vacuum_command_topics_extra
# ---------------------------------------------------------------------------


def test_vacuum_command_topics_extra_includes_command_topics():
    extra = contract.vacuum_command_topics_extra(PREFIX, "roomba1", "vacuum", 13084)
    assert extra["command_topic"] == "ha2fhem/devices/roomba1/vacuum/set"
    assert extra["set_fan_speed_topic"] == "ha2fhem/devices/roomba1/vacuum/set_fan_speed"
    assert extra["send_command_topic"] == "ha2fhem/devices/roomba1/vacuum/send_command"
    assert extra["supported_features"] == [
        "locate",
        "pause",
        "return_home",
        "send_command",
        "start",
        "status",
        "stop",
    ]
    assert "fan_speed_list" not in extra


def test_vacuum_command_topics_extra_includes_fan_speed_list_only_with_fan_speed_bit():
    extra = contract.vacuum_command_topics_extra(
        PREFIX,
        "roomba1",
        "vacuum",
        contract.VACUUM_FEATURE_FAN_SPEED,
        fan_speed_list=["min", "medium", "high", "max"],
    )
    assert extra["supported_features"] == ["fan_speed"]
    assert extra["fan_speed_list"] == ["min", "medium", "high", "max"]


def test_vacuum_command_topics_extra_no_fan_speed_bit_omits_fan_speed_list_even_if_given():
    extra = contract.vacuum_command_topics_extra(
        PREFIX,
        "roomba1",
        "vacuum",
        contract.VACUUM_FEATURE_START,
        fan_speed_list=["min", "max"],
    )
    assert "fan_speed_list" not in extra


def test_vacuum_command_topics_extra_zero_features_omits_key():
    # 0 = unknown (entity unavailable at startup) -> key omitted per
    # CONTRACT.md, FHEM then exposes all setters instead of none
    extra = contract.vacuum_command_topics_extra(PREFIX, "roomba1", "vacuum", 0)
    assert "supported_features" not in extra
    assert "fan_speed_list" not in extra
    assert extra["command_topic"] == f"{PREFIX}/devices/roomba1/vacuum/set"


def test_vacuum_command_topics_extra_merges_into_discovery_payload_via_extra():
    # This is how publisher.py wires it: extra = {"schema": "state", **vacuum_command_topics_extra(...)}
    extra = {"schema": "state"}
    extra.update(
        contract.vacuum_command_topics_extra(
            PREFIX, "roomba1", "vacuum", contract.VACUUM_FEATURE_FAN_SPEED, ["min", "max"]
        )
    )
    payload = contract.discovery_payload(
        PREFIX, "vacuum", "roomba1", "vacuum", "Roomba", "Roomba", extra=extra
    )
    assert payload["command_topic"] == "ha2fhem/devices/roomba1/vacuum/set"
    assert payload["set_fan_speed_topic"] == "ha2fhem/devices/roomba1/vacuum/set_fan_speed"
    assert payload["send_command_topic"] == "ha2fhem/devices/roomba1/vacuum/send_command"
    assert payload["supported_features"] == ["fan_speed"]
    assert payload["fan_speed_list"] == ["min", "max"]
    # unaffected structural fields
    assert payload["unique_id"] == "ha2fhem_roomba1_vacuum"


def test_discovery_payload_sibling_sensor_has_no_command_topics():
    # Sensor/binary_sensor siblings never get vacuum command topics -- only
    # the main (controllable) entity does. publisher.py only calls
    # vacuum_command_topics_extra for is_main entities, so a sibling's extra
    # is None/absent; document that the resulting payload stays untouched.
    payload = contract.discovery_payload(
        PREFIX, "sensor", "roomba1", "battery", "Roomba", "Battery"
    )
    assert "command_topic" not in payload
    assert "set_fan_speed_topic" not in payload
    assert "send_command_topic" not in payload
    assert "supported_features" not in payload
    assert "fan_speed_list" not in payload


# ---------------------------------------------------------------------------
# cover_state_payload — cross-checked against the CONTRACT.md example:
# {"state": "open", "position": 75}
# ---------------------------------------------------------------------------


def test_cover_state_payload_contract_example():
    payload = contract.cover_state_payload(state="open", position=75)
    assert payload == {"state": "open", "position": 75}


def test_cover_state_payload_omits_none_position():
    payload = contract.cover_state_payload(state="closed")
    assert payload == {"state": "closed"}
    assert "position" not in payload


@pytest.mark.parametrize(
    "state", ["open", "opening", "closed", "closing", "stopped"]
)
def test_cover_state_payload_accepts_all_contract_states(state):
    payload = contract.cover_state_payload(state=state)
    assert payload["state"] == state


def test_cover_state_payload_rejects_invalid_state():
    with pytest.raises(ValueError, match="invalid cover state"):
        contract.cover_state_payload(state="ajar")


def test_cover_state_payload_rejects_empty_state():
    with pytest.raises(ValueError):
        contract.cover_state_payload(state="")


def test_cover_state_payload_position_zero_is_not_omitted():
    # position=0 must survive: "not None" is the omission test, not truthiness
    payload = contract.cover_state_payload(state="closed", position=0)
    assert payload == {"state": "closed", "position": 0}


# ---------------------------------------------------------------------------
# cover_features — bitmask -> contract feature names
# (homeassistant.components.cover.CoverEntityFeature bit values)
# ---------------------------------------------------------------------------


def test_cover_features_zero_is_empty():
    assert contract.cover_features(0) == []


def test_cover_features_full_mask_has_everything():
    full_mask = (
        contract.COVER_FEATURE_OPEN
        | contract.COVER_FEATURE_CLOSE
        | contract.COVER_FEATURE_SET_POSITION
        | contract.COVER_FEATURE_STOP
    )
    assert contract.cover_features(full_mask) == ["close", "open", "set_position", "stop"]


def test_cover_features_partial_mask():
    mask = contract.COVER_FEATURE_OPEN | contract.COVER_FEATURE_CLOSE
    assert contract.cover_features(mask) == ["close", "open"]
    assert "stop" not in contract.cover_features(mask)
    assert "set_position" not in contract.cover_features(mask)


# ---------------------------------------------------------------------------
# cover_command_topics_extra
# ---------------------------------------------------------------------------


def test_cover_command_topics_extra_includes_command_topics():
    full_mask = (
        contract.COVER_FEATURE_OPEN
        | contract.COVER_FEATURE_CLOSE
        | contract.COVER_FEATURE_STOP
    )
    extra = contract.cover_command_topics_extra(PREFIX, "blind1", "cover", full_mask)
    assert extra["command_topic"] == "ha2fhem/devices/blind1/cover/set"
    assert extra["set_position_topic"] == "ha2fhem/devices/blind1/cover/set_position"
    assert extra["supported_features"] == ["close", "open", "stop"]


def test_cover_command_topics_extra_zero_features_omits_key():
    # 0 = unknown (entity unavailable at startup) -> key omitted per
    # CONTRACT.md, FHEM then exposes all setters instead of none
    extra = contract.cover_command_topics_extra(PREFIX, "blind1", "cover", 0)
    assert "supported_features" not in extra
    assert extra["command_topic"] == f"{PREFIX}/devices/blind1/cover/set"
    assert extra["set_position_topic"] == f"{PREFIX}/devices/blind1/cover/set_position"


def test_cover_command_topics_extra_merges_into_discovery_payload_via_extra():
    extra = {"schema": "state"}
    extra.update(
        contract.cover_command_topics_extra(
            PREFIX, "blind1", "cover", contract.COVER_FEATURE_SET_POSITION
        )
    )
    payload = contract.discovery_payload(
        PREFIX, "cover", "blind1", "cover", "Blind", "Blind", extra=extra
    )
    assert payload["command_topic"] == "ha2fhem/devices/blind1/cover/set"
    assert payload["set_position_topic"] == "ha2fhem/devices/blind1/cover/set_position"
    assert payload["supported_features"] == ["set_position"]
    assert payload["unique_id"] == "ha2fhem_blind1_cover"


# ---------------------------------------------------------------------------
# parse_command_topic — set_position kind
# ---------------------------------------------------------------------------


def test_parse_command_topic_set_position():
    topic = "ha2fhem/devices/blind1/cover/set_position"
    assert contract.parse_command_topic(PREFIX, topic) == ("blind1", "cover", "set_position")


# ---------------------------------------------------------------------------
# command_to_service — cover mappings
# ---------------------------------------------------------------------------


def test_command_to_service_cover_open():
    assert contract.command_to_service("cover", "set", "OPEN") == ("open_cover", {})


def test_command_to_service_cover_close():
    assert contract.command_to_service("cover", "set", "CLOSE") == ("close_cover", {})


def test_command_to_service_cover_stop():
    assert contract.command_to_service("cover", "set", "STOP") == ("stop_cover", {})


def test_command_to_service_cover_unknown_set_payload_is_none():
    assert contract.command_to_service("cover", "set", "bogus") is None


def test_command_to_service_cover_lowercase_payload_is_none():
    # CONTRACT.md mandates the HA MQTT cover platform's uppercase payloads
    assert contract.command_to_service("cover", "set", "open") is None


def test_command_to_service_cover_set_position():
    assert contract.command_to_service("cover", "set_position", "42") == (
        "set_cover_position",
        {"position": 42},
    )


@pytest.mark.parametrize("payload", ["0", "100"])
def test_command_to_service_cover_set_position_boundaries(payload):
    assert contract.command_to_service("cover", "set_position", payload) == (
        "set_cover_position",
        {"position": int(payload)},
    )


@pytest.mark.parametrize("payload", ["-1", "101", "abc", "", "50.5"])
def test_command_to_service_cover_set_position_rejects_out_of_range_or_non_integer(payload):
    assert contract.command_to_service("cover", "set_position", payload) is None


def test_command_to_service_cover_unknown_topic_kind_is_none():
    assert contract.command_to_service("cover", "send_command", "start") is None


def test_command_to_service_unknown_component_is_none():
    assert contract.command_to_service("climate", "set", "ON") is None


# ---------------------------------------------------------------------------
# switch_state_payload / light_state_payload — cross-checked against
# CONTRACT.md "Component: switch" / "Component: light" examples:
# {"state": "on"} / {"state": "on", "brightness": 128}
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("state", ["on", "off"])
def test_switch_state_payload_accepts_contract_states(state):
    assert contract.switch_state_payload(state=state) == {"state": state}


def test_switch_state_payload_rejects_invalid_state():
    with pytest.raises(ValueError, match="invalid switch state"):
        contract.switch_state_payload(state="unknown")


def test_switch_state_payload_rejects_empty_state():
    with pytest.raises(ValueError):
        contract.switch_state_payload(state="")


@pytest.mark.parametrize("state", ["on", "off"])
def test_light_state_payload_accepts_contract_states(state):
    assert contract.light_state_payload(state=state) == {"state": state}


def test_light_state_payload_contract_example():
    payload = contract.light_state_payload(state="on", brightness=128)
    assert payload == {"state": "on", "brightness": 128}


def test_light_state_payload_omits_none_brightness():
    payload = contract.light_state_payload(state="off")
    assert payload == {"state": "off"}
    assert "brightness" not in payload


def test_light_state_payload_brightness_zero_is_not_omitted():
    # brightness=0 must survive: "not None" is the omission test, not truthiness
    payload = contract.light_state_payload(state="on", brightness=0)
    assert payload == {"state": "on", "brightness": 0}


def test_light_state_payload_rejects_invalid_state():
    with pytest.raises(ValueError, match="invalid light state"):
        contract.light_state_payload(state="unknown")


def test_light_state_payload_rejects_empty_state():
    with pytest.raises(ValueError):
        contract.light_state_payload(state="")


# ---------------------------------------------------------------------------
# switch_command_topics_extra / light_command_topics_extra
# ---------------------------------------------------------------------------


def test_switch_command_topics_extra_includes_command_topic_only():
    extra = contract.switch_command_topics_extra(PREFIX, "sw1", "switch")
    assert extra == {"command_topic": "ha2fhem/devices/sw1/switch/set"}


def test_light_command_topics_extra_includes_command_topic_only():
    extra = contract.light_command_topics_extra(PREFIX, "lamp1", "light")
    assert extra == {"command_topic": "ha2fhem/devices/lamp1/light/set"}


def test_switch_command_topics_extra_merges_into_discovery_payload_via_extra():
    extra = {"schema": "state"}
    extra.update(contract.switch_command_topics_extra(PREFIX, "sw1", "switch"))
    payload = contract.discovery_payload(
        PREFIX, "switch", "sw1", "switch", "Switch", "Switch", extra=extra
    )
    assert payload["command_topic"] == "ha2fhem/devices/sw1/switch/set"
    assert "supported_features" not in payload
    assert payload["unique_id"] == "ha2fhem_sw1_switch"


def test_light_command_topics_extra_merges_into_discovery_payload_via_extra():
    extra = {"schema": "state"}
    extra.update(contract.light_command_topics_extra(PREFIX, "lamp1", "light"))
    payload = contract.discovery_payload(
        PREFIX, "light", "lamp1", "light", "Light", "Light", extra=extra
    )
    assert payload["command_topic"] == "ha2fhem/devices/lamp1/light/set"
    assert "supported_features" not in payload
    assert payload["unique_id"] == "ha2fhem_lamp1_light"


# ---------------------------------------------------------------------------
# command_to_service — switch / light mappings
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("component", ["switch", "light"])
def test_command_to_service_switch_light_on(component):
    assert contract.command_to_service(component, "set", "ON") == ("turn_on", {})


@pytest.mark.parametrize("component", ["switch", "light"])
def test_command_to_service_switch_light_off(component):
    assert contract.command_to_service(component, "set", "OFF") == ("turn_off", {})


@pytest.mark.parametrize("component", ["switch", "light"])
def test_command_to_service_switch_light_lowercase_payload_is_none(component):
    # CONTRACT.md mandates the HA MQTT platform's uppercase ON/OFF payloads
    assert contract.command_to_service(component, "set", "on") is None


@pytest.mark.parametrize("component", ["switch", "light"])
def test_command_to_service_switch_light_empty_payload_is_none(component):
    assert contract.command_to_service(component, "set", "") is None


@pytest.mark.parametrize("component", ["switch", "light"])
def test_command_to_service_switch_light_unknown_payload_is_none(component):
    assert contract.command_to_service(component, "set", "bogus") is None


def test_command_to_service_set_position_on_switch_is_none():
    # switch has no set_position topic_kind; regression against cover's schema
    assert contract.command_to_service("switch", "set_position", "42") is None


def test_command_to_service_set_position_on_light_is_none():
    assert contract.command_to_service("light", "set_position", "42") is None


# ---------------------------------------------------------------------------
# Regression: vacuum/cover behavior is unchanged by the switch/light additions
# ---------------------------------------------------------------------------


def test_command_to_service_vacuum_cover_unaffected_by_switch_light_additions():
    assert contract.command_to_service("vacuum", "set", "start") == ("start", {})
    assert contract.command_to_service("cover", "set", "OPEN") == ("open_cover", {})
    assert contract.command_to_service("cover", "set", "ON") is None
    assert contract.command_to_service("vacuum", "set", "ON") is None
