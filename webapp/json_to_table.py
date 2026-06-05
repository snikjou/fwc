"""
Flatten a structured JSON object (e.g. a data-sharing agreement) into a
single two-column table with the columns "Field" and "Value".

- Nested objects are flattened with dot notation:        a.b.c
- Arrays are expanded with bracket-indexing:             a[0].b
- Lists of primitives are joined with "; " on one row:   parties = "X; Y; Z"
- All original string values are preserved verbatim.

The function is generic and works for any JSON-like dict/list structure.
"""

from __future__ import annotations

import json
from typing import Any, Iterable

import pandas as pd


def _is_primitive_list(value: Any) -> bool:
    """Return True if `value` is a list whose items are all primitives
    (str, int, float, bool, None)."""
    return isinstance(value, list) and all(
        not isinstance(item, (dict, list)) for item in value
    )


def _format_primitive(value: Any) -> str:
    """Render a primitive JSON value as a string, preserving its content."""
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def flatten_json(
    data: Any,
    parent_key: str = "",
    separator: str = ".",
) -> list[tuple[str, str]]:
    """Recursively flatten a JSON-like object into a list of
    (field_path, value) tuples.

    Parameters
    ----------
    data : Any
        The JSON-like object (dict, list, or primitive).
    parent_key : str
        Accumulated dotted path used during recursion.
    separator : str
        Separator used between nested object keys.

    Returns
    -------
    list[tuple[str, str]]
        Flat list of (field, value) pairs in document order.
    """
    rows: list[tuple[str, str]] = []

    # --- Object: recurse into each key ---------------------------------
    if isinstance(data, dict):
        for key, value in data.items():
            new_key = f"{parent_key}{separator}{key}" if parent_key else key
            rows.extend(flatten_json(value, new_key, separator))
        return rows

    # --- List ----------------------------------------------------------
    if isinstance(data, list):
        # Lists of primitives -> one row, semicolon-joined values.
        if _is_primitive_list(data):
            joined = "; ".join(_format_primitive(item) for item in data)
            rows.append((parent_key, joined))
            return rows

        # Lists of objects/lists -> expand with [index] notation.
        for index, item in enumerate(data):
            indexed_key = f"{parent_key}[{index}]"
            rows.extend(flatten_json(item, indexed_key, separator))
        return rows

    # --- Primitive leaf ------------------------------------------------
    rows.append((parent_key, _format_primitive(data)))
    return rows


def json_to_table(data: Any) -> pd.DataFrame:
    """Convert a JSON-like object into a 2-column DataFrame with
    columns "Field" and "Value"."""
    rows = flatten_json(data)
    return pd.DataFrame(rows, columns=["Field", "Value"])


# ----------------------------------------------------------------------
# Example usage
# ----------------------------------------------------------------------
if __name__ == "__main__":
    sample_json = {
        "agreementTitle": "Data Sharing Agreement",
        "effectiveDate": "2025-01-01",
        "parties": ["Contoso Ltd.", "Fabrikam Inc.", "Northwind Traders"],
        "metadata": {
            "version": "1.2",
            "confidential": True,
        },
        "dataTypes": [
            {"dataType": "PII", "sensitivity": "High"},
            {"dataType": "Telemetry", "sensitivity": "Low"},
        ],
        "dataSharingPages": [
            {"pageNumber": 1, "section": "Purpose"},
            {"pageNumber": 2, "section": "Obligations"},
        ],
    }

    df = json_to_table(sample_json)
    print(df.to_string(index=False))
