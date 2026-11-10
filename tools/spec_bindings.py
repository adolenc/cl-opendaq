#!/usr/bin/env python3
"""
spec_bindings.py - Turn opendaq.json into the stream of binding records the
generators work from (functions, interfaces, enums, typedefs, error codes).

opendaq.json is the machine-readable description of the openDAQ C API that the
openDAQ generators produce next to the C bindings.  It describes exactly what
the C library exports, in C spelling, and defines every type it uses, so this
script holds no tables of its own: it only flattens the file into records.

The one rule it applies is how the C functions of an interface are named:

    <interface>_getInterfaceId(daqIntfID* intfId)
    <interface>_<method>(<interface>* self, ...)
    <interface>_<factory>(...)
    <interface>_<function>(...)

Usage:
    python spec_bindings.py --spec tmp/nightly/<tag>/opendaq.json
    python spec_bindings.py --spec tmp/nightly/<tag>/opendaq.json --kinds function interface

Each line of stdout is a JSON object with a "kind" discriminator.  Example:

  {"kind": "function",
   "name": "daqDevice_addDevices",
   "return_type": {"name": "daqErrCode"},
   "arguments": [
     {"name": "self",           "type": {"name": "daqDevice", "pointer_depth": 1}},
     {"name": "devices",        "type": {"name": "daqDict", "pointer_depth": 2, "key_type": "daqString", "value_type": "daqDevice"}},
     {"name": "connectionArgs", "type": {"name": "daqDict", "pointer_depth": 1, "key_type": "daqString", "value_type": "daqPropertyObject"}}
   ],
   "docstring": "@brief Connects to multiple devices in parallel ...\\n...",
   "source_file": "core/opendaq/device/include/opendaq/device.h"}

Record schema (per kind):

  function:
    name           : str     - the C function (e.g. "daqDevice_addDevices");
                               class / method split on the first '_'
    return_type    : TypeDesc
    arguments[]    : { name: str, type: TypeDesc, default_value: str? }
    docstring      : str     - doxygen text with newlines preserved
    source_file    : str     - the core header that declares it

  interface:
    name           : str     - e.g. "daqDevice"
    parent         : str     - the base interface ("" for daqUnknown)
    docstring      : str
    source_file    : str

  typedef:
    name           : str     - C typedef name
    category       : "opaque" | "struct" | "enum" | "callback" | "alias"
    pointer_depth  : int     - present only when > 0
    base_type      : str     - (alias only) underlying type name
    enum_entries[] : { name: str, value: int }
    struct_fields[]: { name: str, type: TypeDesc } - with aliases resolved to
                               the C types they stand for

  error_code:
    name           : str     - e.g. "OPENDAQ_ERR_NOTFOUND", "OPENDAQ_SUCCESS"
    code           : int     - full 32-bit status code
    source_file    : str

  TypeDesc  (inline object, never a top-level record):
    name           : str     - C base type (e.g. "daqDict", "daqCSizeT", "void")
    pointer_depth  : int?    - (>0 only) number of '*' levels
    key_type       : str?    - (Dict only) key type
    value_type     : str?    - (List/Dict only) element/value type
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SUPPORTED_SCHEMA = "opendaq-bindings/1"

# Where the spec's `types` are declared.
ABI_HEADER = "bindings/c/include/ccommon.h"


class SpecError(ValueError):
    pass


def load_spec(path: Path) -> dict:
    spec = json.loads(Path(path).read_text(encoding="utf-8"))
    schema = spec.get("schema")
    if schema != SUPPORTED_SCHEMA:
        raise SpecError(f"{path}: schema {schema!r} is not supported (expected {SUPPORTED_SCHEMA!r})")
    return spec


def load_records(spec_path: Path) -> list[dict]:
    """All binding records of the spec, in a stable order."""
    return records_from_spec(load_spec(spec_path))


def type_desc(type_: dict) -> dict:
    desc: dict = {"name": type_["name"]}
    # A reference (is_reference) is how C++ passes a value type; C takes the value.
    if type_.get("pointers"):
        desc["pointer_depth"] = type_["pointers"]
    # Events carry their sender/argument types the way dictionaries carry
    # key/value types.
    key = type_.get("key_type") or type_.get("sender_type")
    value = type_.get("value_type") or type_.get("args_type")
    if key:
        desc["key_type"] = key
    if value:
        desc["value_type"] = value
    return desc


def records_from_spec(spec: dict) -> list[dict]:
    aliases = {t["name"]: t["type"] for t in spec["types"] if t["kind"] == "alias"}

    def resolved(type_: dict) -> dict:
        """The type with aliases replaced by the C types they stand for."""
        name, pointers = type_["name"], type_.get("pointers", 0)
        while name in aliases:
            pointers += aliases[name].get("pointers", 0)
            name = aliases[name]["name"]
        return type_desc({"name": name, "pointers": pointers})

    def function(name: str, member: dict, source_file: str, self_type: str | None = None) -> dict:
        arguments = []
        if self_type:
            arguments.append({"name": "self", "type": {"name": self_type, "pointer_depth": 1}})
        for argument in member["arguments"]:
            record = {"name": argument["name"], "type": type_desc(argument["type"])}
            if "default_value" in argument:
                record["default_value"] = argument["default_value"]
            arguments.append(record)
        return {
            "kind": "function",
            "name": name,
            "return_type": type_desc(member["return_type"]),
            "arguments": arguments,
            "docstring": member.get("doc", ""),
            "source_file": source_file,
        }

    records: list[dict] = []

    for type_ in spec["types"]:
        record = {"kind": "typedef", "name": type_["name"], "category": type_["kind"]}
        if type_["kind"] == "alias":
            record["base_type"] = type_["type"]["name"]
            if type_["type"].get("pointers"):
                record["pointer_depth"] = type_["type"]["pointers"]
        elif type_["kind"] == "struct":
            record["struct_fields"] = [{"name": f["name"], "type": resolved(f["type"])} for f in type_["fields"]]
        elif type_["kind"] == "callback":
            record["pointer_depth"] = 1
        records.append({**record, "docstring": "", "source_file": ABI_HEADER})
    defined = {t["name"] for t in spec["types"]}

    for enum in spec["enums"]:
        records.append({
            "kind": "typedef",
            "name": enum["name"],
            "category": "enum",
            "enum_entries": [{"name": o["name"], "value": o["value"]} for o in enum["options"]],
            "docstring": enum.get("doc", ""),
            "source_file": enum.get("header", ""),
        })

    for interface in spec["interfaces"]:
        name = interface["name"]
        header = interface.get("header", "")

        records.append({
            "kind": "interface",
            "name": name,
            "parent": interface.get("base", ""),
            "docstring": interface.get("doc", ""),
            "source_file": header,
        })
        # The handle of an interface is an opaque struct, unless `types` says
        # otherwise (daqBaseObject and daqUnknown are plain void).
        if name not in defined:
            records.append({"kind": "typedef", "name": name, "category": "opaque",
                            "docstring": "", "source_file": header})

        records.append({
            "kind": "function",
            "name": f"{name}_getInterfaceId",
            "return_type": {"name": "void"},
            "arguments": [{"name": "intfId", "type": {"name": "daqIntfID", "pointer_depth": 1}}],
            "docstring": "",
            "source_file": header,
        })
        for method in interface["methods"]:
            records.append(function(f"{name}_{method['name']}", method, header, self_type=name))
        for member in interface.get("factories", []) + interface.get("functions", []):
            records.append(function(f"{name}_{member['name']}", member, member.get("header", header)))

    for code in spec["error_codes"]:
        # The records name a status code as the core does (OPENDAQ_...), which
        # is what the bindings have always exposed; C spells it DAQ_...
        name = code["name"]
        if name.startswith("DAQ_"):
            name = "OPEN" + name
        records.append({"kind": "error_code", "name": name, "code": code["code"],
                        "source_file": code.get("header", "")})

    return records


def main() -> None:
    ap = argparse.ArgumentParser(description="Emit the binding records of an opendaq.json as JSONL.")
    ap.add_argument("--spec", type=Path, required=True, help="Path to opendaq.json.")
    ap.add_argument(
        "--kinds",
        nargs="+",
        choices=["function", "interface", "typedef", "error_code"],
        default=["function", "interface", "typedef", "error_code"],
        help="Which kinds of binding records to emit (default: all).",
    )
    args = ap.parse_args()

    try:
        records = load_records(args.spec)
    except SpecError as error:
        sys.exit(str(error))
    kinds = set(args.kinds)
    for record in records:
        if record["kind"] in kinds:
            print(json.dumps(record))


if __name__ == "__main__":
    main()
