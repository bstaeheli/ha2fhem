"""Config flow for ha2fhem."""

from __future__ import annotations

from typing import Any

import voluptuous as vol
from homeassistant import config_entries
from homeassistant.core import HomeAssistant
from homeassistant.helpers import selector

from .const import (
    CONF_EXCLUDE_DEVICES,
    CONF_EXCLUDE_DOMAINS,
    CONF_EXCLUDE_INTEGRATIONS,
    CONF_INCLUDE_DEVICES,
    CONF_INCLUDE_DOMAINS,
    CONF_INCLUDE_INTEGRATIONS,
    CONF_TOPIC_PREFIX,
    DEFAULT_TOPIC_PREFIX,
    DOMAIN,
)
from .publisher import MAIN_DOMAINS


def _multi_select(options: list[str]) -> selector.SelectSelector:
    return selector.SelectSelector(
        selector.SelectSelectorConfig(
            options=options,
            multiple=True,
            custom_value=True,
            mode=selector.SelectSelectorMode.DROPDOWN,
        )
    )


def _build_schema(hass: HomeAssistant, current: dict[str, Any]) -> vol.Schema:
    """Shared form for config and options flow (they show the same fields)."""
    domains = list(MAIN_DOMAINS)
    integrations = sorted(
        {e.domain for e in hass.config_entries.async_entries()} - {DOMAIN}
    )
    return vol.Schema(
        {
            vol.Required(
                CONF_TOPIC_PREFIX,
                default=current.get(CONF_TOPIC_PREFIX, DEFAULT_TOPIC_PREFIX),
            ): str,
            vol.Optional(
                CONF_INCLUDE_DOMAINS, default=current.get(CONF_INCLUDE_DOMAINS, [])
            ): _multi_select(domains),
            vol.Optional(
                CONF_EXCLUDE_DOMAINS, default=current.get(CONF_EXCLUDE_DOMAINS, [])
            ): _multi_select(domains),
            vol.Optional(
                CONF_INCLUDE_INTEGRATIONS,
                default=current.get(CONF_INCLUDE_INTEGRATIONS, []),
            ): _multi_select(integrations),
            vol.Optional(
                CONF_EXCLUDE_INTEGRATIONS,
                default=current.get(CONF_EXCLUDE_INTEGRATIONS, []),
            ): _multi_select(integrations),
            vol.Optional(
                CONF_INCLUDE_DEVICES, default=current.get(CONF_INCLUDE_DEVICES, "")
            ): str,
            vol.Optional(
                CONF_EXCLUDE_DEVICES, default=current.get(CONF_EXCLUDE_DEVICES, "")
            ): str,
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

        if user_input is not None:
            return self.async_create_entry(
                title=user_input.get(CONF_TOPIC_PREFIX, DEFAULT_TOPIC_PREFIX),
                data=user_input,
            )

        return self.async_show_form(
            step_id="user", data_schema=_build_schema(self.hass, {}), errors={}
        )

    @staticmethod
    def async_get_options_flow(
        config_entry: config_entries.ConfigEntry,
    ) -> config_entries.OptionsFlow:
        return Ha2fhemOptionsFlow()


class Ha2fhemOptionsFlow(config_entries.OptionsFlow):
    """Options flow letting all filters/topic_prefix be edited post-setup."""

    async def async_step_init(
        self, user_input: dict[str, Any] | None = None
    ) -> config_entries.ConfigFlowResult:
        if user_input is not None:
            return self.async_create_entry(data=user_input)

        current = {**self.config_entry.data, **self.config_entry.options}
        return self.async_show_form(
            step_id="init", data_schema=_build_schema(self.hass, current)
        )
