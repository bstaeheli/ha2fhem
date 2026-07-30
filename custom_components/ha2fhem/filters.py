"""Device filtering: domains, integrations, device ids/names.

Deliberately free of homeassistant imports so tests/ha/test_filter.py can
load it by file path without HA installed (same rule as contract.py).
"""

from __future__ import annotations

from dataclasses import dataclass, field


def _matches_filter(value: str, filter_str: str) -> bool:
    items = {v.strip() for v in filter_str.split(",") if v.strip()}
    return value in items


@dataclass(frozen=True)
class DeviceFilter:
    """Exclude wins first; then every non-empty include list must match."""

    include_devices: str = ""
    exclude_devices: str = ""
    include_domains: list[str] = field(default_factory=list)
    exclude_domains: list[str] = field(default_factory=list)
    include_integrations: list[str] = field(default_factory=list)
    exclude_integrations: list[str] = field(default_factory=list)

    def allows(
        self, domain: str, platform: str, device_id: str, device_name: str
    ) -> bool:
        if domain in self.exclude_domains:
            return False
        if platform in self.exclude_integrations:
            return False
        if self.exclude_devices and (
            _matches_filter(device_id, self.exclude_devices)
            or _matches_filter(device_name, self.exclude_devices)
        ):
            return False
        if self.include_domains and domain not in self.include_domains:
            return False
        if self.include_integrations and platform not in self.include_integrations:
            return False
        if self.include_devices and not (
            _matches_filter(device_id, self.include_devices)
            or _matches_filter(device_name, self.include_devices)
        ):
            return False
        return True
