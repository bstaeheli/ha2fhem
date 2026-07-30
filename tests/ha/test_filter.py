"""Unit tests for custom_components/ha2fhem/filters.py.

Imported by file path like test_contract.py so the suite never touches
`homeassistant` (not installed here); also guards that filters.py stays
free of homeassistant imports.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

_FILTERS_PATH = (
    Path(__file__).resolve().parents[2]
    / "custom_components"
    / "ha2fhem"
    / "filters.py"
)

_spec = importlib.util.spec_from_file_location("ha2fhem_filters", _FILTERS_PATH)
filters = importlib.util.module_from_spec(_spec)
sys.modules["ha2fhem_filters"] = filters
_spec.loader.exec_module(filters)

DeviceFilter = filters.DeviceFilter


def _allows(f: DeviceFilter, domain="vacuum", platform="roomba", device_id="dev1", device_name="Robo") -> bool:
    return f.allows(domain, platform, device_id, device_name)


def test_empty_filter_allows_everything():
    assert _allows(DeviceFilter())


def test_exclude_domain_wins_over_include():
    f = DeviceFilter(include_domains=["vacuum"], exclude_domains=["vacuum"])
    assert not _allows(f)


def test_exclude_integration():
    f = DeviceFilter(exclude_integrations=["roomba"])
    assert not _allows(f, platform="roomba")
    assert _allows(f, platform="overkiz")


def test_exclude_device_by_id_and_name():
    f = DeviceFilter(exclude_devices="dev1, Other")
    assert not _allows(f, device_id="dev1")
    assert not _allows(f, device_id="dev2", device_name="Other")
    assert _allows(f, device_id="dev2", device_name="Robo")


def test_include_domains_only_listed():
    f = DeviceFilter(include_domains=["light", "cover"])
    assert _allows(f, domain="light")
    assert not _allows(f, domain="vacuum")


def test_include_integrations_only_listed():
    f = DeviceFilter(include_integrations=["overkiz"])
    assert _allows(f, platform="overkiz")
    assert not _allows(f, platform="roomba")


def test_includes_are_anded_across_dimensions():
    f = DeviceFilter(include_domains=["vacuum"], include_integrations=["roomba"])
    assert _allows(f, domain="vacuum", platform="roomba")
    assert not _allows(f, domain="vacuum", platform="overkiz")
    assert not _allows(f, domain="cover", platform="roomba")


def test_include_devices_by_id_or_name():
    f = DeviceFilter(include_devices="dev1,Fancy Name")
    assert _allows(f, device_id="dev1")
    assert _allows(f, device_id="dev2", device_name="Fancy Name")
    assert not _allows(f, device_id="dev2", device_name="Robo")


def test_empty_include_list_leaves_dimension_unfiltered():
    f = DeviceFilter(include_domains=[], include_integrations=["roomba"])
    assert _allows(f, domain="cover", platform="roomba")
