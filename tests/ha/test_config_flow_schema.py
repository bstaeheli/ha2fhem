"""Regression test for the options-flow schema markers in config_flow.py.

config_flow.py imports homeassistant, which is not installed here, so the
`_optional` helper is lifted out of the file's AST and executed on its own
against real voluptuous. That is enough to pin the behaviour that broke:
a filter the user emptied has to stay empty.
"""

from __future__ import annotations

import ast
from pathlib import Path

import pytest

vol = pytest.importorskip("voluptuous")

_CONFIG_FLOW = (
    Path(__file__).resolve().parents[2]
    / "custom_components"
    / "ha2fhem"
    / "config_flow.py"
)


def _load_optional():
    tree = ast.parse(_CONFIG_FLOW.read_text())
    fn = next(
        n
        for n in tree.body
        if isinstance(n, ast.FunctionDef) and n.name == "_optional"
    )
    ns: dict = {"vol": vol, "Any": object}
    exec(compile(ast.Module(body=[fn], type_ignores=[]), "<config_flow>", "exec"), ns)
    return ns["_optional"]


_optional = _load_optional()

CURRENT = {"include_devices": "dev1", "include_integrations": ["roomba"]}


def _schema():
    return vol.Schema(
        {
            _optional("include_devices", CURRENT, ""): str,
            _optional("include_integrations", CURRENT, []): list,
        }
    )


def test_cleared_field_stays_cleared():
    """The frontend omits a field the user emptied -- it must not come back."""
    assert _schema()({}) == {"include_devices": "", "include_integrations": []}


def test_clearing_one_filter_leaves_the_other():
    assert _schema()({"include_integrations": ["roomba"]}) == {
        "include_devices": "",
        "include_integrations": ["roomba"],
    }


def test_submitted_values_are_kept():
    submitted = {"include_devices": "dev1,dev2", "include_integrations": ["overkiz"]}
    assert _schema()(submitted) == submitted


def test_stored_value_is_offered_as_suggestion_not_as_default():
    marker = _optional("include_devices", CURRENT, "")
    assert marker.description == {"suggested_value": "dev1"}
    assert marker.default() == ""
