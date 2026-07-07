"""Config flow for ha2fhem."""

from __future__ import annotations

from typing import Any

import voluptuous as vol
from homeassistant import config_entries

from .const import (
    CONF_EXCLUDE_DEVICES,
    CONF_INCLUDE_DEVICES,
    CONF_TOPIC_PREFIX,
    DEFAULT_TOPIC_PREFIX,
    DOMAIN,
)

DATA_SCHEMA = vol.Schema(
    {
        vol.Required(CONF_TOPIC_PREFIX, default=DEFAULT_TOPIC_PREFIX): str,
        vol.Optional(CONF_INCLUDE_DEVICES, default=""): str,
        vol.Optional(CONF_EXCLUDE_DEVICES, default=""): str,
    }
)


class Ha2fhemConfigFlow(config_entries.ConfigFlow, domain=DOMAIN):
    """Single-instance, single-step config flow for ha2fhem."""

    VERSION = 1

    async def async_step_user(
        self, user_input: dict[str, Any] | None = None
    ) -> config_entries.ConfigFlowResult:
        if self._async_current_entries():
            return self.async_abort(reason="single_instance_allowed")

        errors: dict[str, str] = {}

        if user_input is not None:
            return self.async_create_entry(
                title=user_input.get(CONF_TOPIC_PREFIX, DEFAULT_TOPIC_PREFIX),
                data=user_input,
            )

        return self.async_show_form(
            step_id="user", data_schema=DATA_SCHEMA, errors=errors
        )
