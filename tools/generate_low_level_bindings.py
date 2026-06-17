#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


BUILTIN_TYPE_MAP = {
    "char": ":char",
    "double": ":double",
    "float": ":float",
    "int": ":int",
    "int8_t": ":int8",
    "int16_t": ":int16",
    "int32_t": ":int32",
    "int64_t": ":int64",
    "size_t": ":size",
    "uint8_t": ":uint8",
    "uint16_t": ":uint16",
    "uint32_t": ":uint32",
    "uint64_t": ":uint64",
    "void": ":void",
}

RAW_BUFFER_PARAMETER_NAMES = {
    "blocks",
    "data",
    "data-blocks",
    "domain",
    "domain-blocks",
    "samples",
    "values",
}

IN_OUT_PARAMETER_OVERRIDES = {
    "daqBlockReader_read": {"count": "in-out"},
    "daqBlockReader_readWithDomain": {"count": "in-out"},
    "daqConnectionInternal_dequeueUpTo": {"count": "in-out"},
    "daqFunction_call": {"result": "in-out"},
    "daqMultiReader_read": {"count": "in-out"},
    "daqMultiReader_readWithDomain": {"count": "in-out"},
    "daqMultiReader_skipSamples": {"count": "in-out"},
    "daqStreamReader_read": {"count": "in-out"},
    "daqStreamReader_readWithDomain": {"count": "in-out"},
    "daqStreamReader_skipSamples": {"count": "in-out"},
    "daqTailReader_read": {"count": "in-out"},
    "daqTailReader_readWithDomain": {"count": "in-out"},
}


def c_identifier_to_lisp(name: str) -> str:
    tokens = []
    for chunk in name.split("_"):
        tokens.extend(
            match.group(0).lower()
            for match in re.finditer(r"[A-Z]+(?=[A-Z][a-z]|[0-9]|\b)|[A-Z]?[a-z]+|[a-z]+|[0-9]+", chunk)
        )
    return "-".join(token for token in tokens if token)


def c_function_to_public_lisp(name: str) -> str:
    receiver, separator, method = name.partition("_")
    if receiver.startswith("daq") and len(receiver) > 3 and receiver[3].isupper():
        receiver = receiver[3:]
    public_receiver = c_identifier_to_lisp(receiver)
    if not separator:
        return public_receiver or c_identifier_to_lisp(name)
    public_method = c_identifier_to_lisp(method)
    return f"{public_receiver}/{public_method}" if public_receiver and public_method else public_receiver or public_method


def wrap_pointer(type_spec: str, depth: int) -> str:
    for _ in range(depth):
        type_spec = f"(:pointer {type_spec})"
    return type_spec


def repo_root(path: Path) -> Path:
    path = path.resolve()
    if path.name != "include":
        return path
    if path.parent.name == "c" and path.parent.parent.name == "bindings":
        return path.parent.parent.parent
    return path.parent


def parse_records(include_dir: Path) -> list[dict]:
    output = subprocess.run(
        [
            sys.executable,
            str(Path(__file__).with_name("parse_bindings.py")),
            "--opendaq-repo",
            str(repo_root(include_dir)),
            "--kinds",
            "typedef",
            "function",
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [json.loads(line) for line in output.splitlines() if line.strip()]


def build_types(records: list[dict]) -> dict[str, dict]:
    typedefs = {record["name"]: record for record in records if record["kind"] == "typedef"}
    types = {}

    def build(name: str) -> dict:
        if name in types:
            return types[name]
        record = typedefs[name]
        lisp_name = c_identifier_to_lisp(name)
        category = record["category"]
        if category == "struct":
            types[name] = {
                "c_name": name,
                "lisp_name": lisp_name,
                "kind": "struct",
                "cffi_spec": f"(:struct {lisp_name})",
                "fields": tuple(
                    (
                        c_identifier_to_lisp(field["name"]),
                        wrap_pointer(BUILTIN_TYPE_MAP[field["type"]["name"]], field["type"].get("pointer_depth", 0)),
                    )
                    for field in record.get("struct_fields", [])
                ),
            }
            return types[name]
        if category == "enum":
            values = [(entry["name"], entry["value"]) for entry in record.get("enum_entries", [])]
            numeric = tuple((entry_name, entry_value) for entry_name, entry_value in values if entry_value is not None)
            seen = set()
            duplicates = False
            for _, value in numeric:
                if value in seen:
                    duplicates = True
                seen.add(value)
            types[name] = {
                "c_name": name,
                "lisp_name": lisp_name,
                "kind": "enum",
                "cffi_spec": lisp_name if not duplicates and all(value is not None for _, value in values) else "daq-enum-type",
                "enum_entries": tuple(
                    (entry_name, "<implicit-after-unsupported>" if entry_value is None else str(entry_value))
                    for entry_name, entry_value in values
                ),
                "numeric_enum_entries": numeric,
                "enum_has_duplicates": duplicates,
                "enum_has_unsupported_values": any(value is None for _, value in values),
            }
            return types[name]
        if category in {"opaque", "callback"} and "base_type" not in record:
            types[name] = {
                "c_name": name,
                "lisp_name": lisp_name,
                "kind": category,
                "cffi_spec": ":pointer",
                "pointer_like": True,
            }
            return types[name]
        base_type = record.get("base_type")
        pointer_depth = record.get("pointer_depth", 0)
        if name == "daqBaseObject" or pointer_depth > 0:
            types[name] = {
                "c_name": name,
                "lisp_name": lisp_name,
                "kind": "pointer-alias",
                "cffi_spec": ":pointer",
                "pointer_like": True,
            }
            return types[name]
        if base_type in BUILTIN_TYPE_MAP:
            types[name] = {"c_name": name, "lisp_name": lisp_name, "kind": "alias", "cffi_spec": BUILTIN_TYPE_MAP[base_type]}
            return types[name]
        aliased = build(base_type)
        types[name] = {
            "c_name": name,
            "lisp_name": lisp_name,
            "kind": "alias",
            "cffi_spec": aliased["lisp_name"],
            "pointer_like": aliased.get("pointer_like", False),
        }
        return types[name]

    for name in typedefs:
        build(name)
    return types


def resolve_cffi_type(base_type: str, pointer_depth: int, types: dict[str, dict]) -> str:
    if base_type in types:
        type_info = types[base_type]
        return type_info["lisp_name"] if pointer_depth == 0 and type_info.get("pointer_like") else wrap_pointer(type_info["lisp_name"], pointer_depth - 1 if type_info.get("pointer_like") else pointer_depth)
    builtin = BUILTIN_TYPE_MAP.get(base_type)
    if builtin is None:
        raise ValueError(f"Unsupported C type: {base_type}")
    return wrap_pointer(":pointer", pointer_depth - 1) if builtin == ":void" and pointer_depth > 0 else wrap_pointer(builtin, pointer_depth)


def parameter_mode(function: dict, parameter: dict) -> str:
    override = IN_OUT_PARAMETER_OVERRIDES.get(function["c_name"], {}).get(parameter["lisp_name"])
    if override:
        return override
    if parameter["pointer_depth"] == 0:
        return "in"
    if parameter["pointer_depth"] == 1 and (parameter["base_kind"] in {"opaque", "callback"} or parameter["base_type"] == "daqBaseObject"):
        return "in"
    if parameter["base_type"] == "void" or parameter["lisp_name"] in RAW_BUFFER_PARAMETER_NAMES:
        return "in"
    return "out"


def build_functions(records: list[dict], types: dict[str, dict]) -> tuple[list[dict], list[tuple[str, str]]]:
    functions = []
    skipped = []
    def by_value_struct(type_spec: dict) -> str | None:
        name = type_spec["name"]
        if type_spec.get("pointer_depth", 0) == 0 and name in types and types[name]["kind"] == "struct":
            return name
        return None

    for record in sorted((record for record in records if record["kind"] == "function"), key=lambda item: item["name"]):
        return_type = record["return_type"]
        base_type = return_type["name"]
        pointer_depth = return_type.get("pointer_depth", 0)
        # Skip functions that pass or return a struct by value.  CFFI can only
        # marshal by-value structs through cffi-libffi, which compiles a small C
        # shim at load time and therefore breaks wherever no C compiler is
        # installed (notably a stock Windows host).  These functions are the
        # binding's only by-value-struct call sites, so dropping them lets us
        # depend on plain cffi alone.
        struct_by_value = by_value_struct(return_type) or next(
            (name for argument in record.get("arguments", []) if (name := by_value_struct(argument["type"]))),
            None,
        )
        if struct_by_value is not None:
            skipped.append((record["name"], f"passes a struct by value, which would require cffi-libffi ({struct_by_value})"))
            continue
        try:
            parameters = []
            for argument in record.get("arguments", []):
                arg_type = argument["type"]
                arg_base = arg_type["name"]
                arg_depth = arg_type.get("pointer_depth", 0)
                base_info = types.get(arg_base)
                parameters.append(
                    {
                        "c_name": argument["name"],
                        "lisp_name": c_identifier_to_lisp(argument["name"]),
                        "cffi_spec": resolve_cffi_type(arg_base, arg_depth, types),
                        "base_type": arg_base,
                        "base_lisp_name": base_info["lisp_name"] if base_info else BUILTIN_TYPE_MAP[arg_base],
                        "base_kind": base_info["kind"] if base_info else "builtin",
                        "pointer_depth": arg_depth,
                        "pointer_like": base_info.get("pointer_like", False) if base_info else False,
                        "pointee_cffi_spec": resolve_cffi_type(arg_base, arg_depth - 1, types) if arg_depth else None,
                        "pointee_kind": base_info["kind"] if base_info else "builtin" if arg_base in BUILTIN_TYPE_MAP else None,
                        "value_type": arg_type.get("value_type"),
                        "key_type": arg_type.get("key_type"),
                    }
                )
            functions.append(
                {
                    "c_name": record["name"],
                    "raw_lisp_name": "%" + c_identifier_to_lisp(record["name"]),
                    "public_lisp_name": c_function_to_public_lisp(record["name"]),
                    "return_spec": resolve_cffi_type(base_type, pointer_depth, types),
                    "parameters": tuple(parameters),
                    "docstring": record.get("docstring", ""),
                }
            )
        except ValueError as exc:
            skipped.append((record["name"], str(exc)))
    return functions, skipped


def can_auto_wrap(function: dict) -> bool:
    return all(
        parameter_mode(function, parameter) == "in"
        or (parameter["pointee_cffi_spec"] is not None and parameter["pointee_kind"] != "struct")
        for parameter in function["parameters"]
    )


def emit_call(function_name: str, arguments) -> str:
    arguments = " ".join(arguments)
    return f"({function_name} {arguments})" if arguments else f"({function_name})"


def emit_type_section(types: dict[str, dict]) -> list[str]:
    lines = [";;; Types"]
    emitted = set()
    for type_info in sorted(types.values(), key=lambda item: item["lisp_name"]):
        if type_info["kind"] in {"alias", "pointer-alias", "opaque", "callback"} and type_info["lisp_name"] not in emitted:
            lines.append(f"(cffi:defctype {type_info['lisp_name']} {type_info['cffi_spec']})")
            emitted.add(type_info["lisp_name"])
    for type_info in sorted(types.values(), key=lambda item: item["lisp_name"]):
        if type_info["kind"] != "struct":
            continue
        lines.extend(["", f"(cffi:defcstruct {type_info['lisp_name']}"])
        lines.extend(f"  ({field_name} {field_type})" for field_name, field_type in type_info["fields"])
        lines.extend(["  )", f"(cffi:defctype {type_info['lisp_name']} (:struct {type_info['lisp_name']}))"])
    for type_info in sorted(types.values(), key=lambda item: item["lisp_name"]):
        if type_info["kind"] != "enum":
            continue
        lines.append("")
        if type_info["enum_has_duplicates"] or type_info["enum_has_unsupported_values"]:
            lines.append(f";; {type_info['c_name']} uses duplicate or unsupported enum values; emit a raw enum alias plus constants/comments.")
            lines.append(f"(cffi:defctype {type_info['lisp_name']} daq-enum-type)")
            for entry_name, entry_value in type_info["enum_entries"]:
                if entry_value.startswith("<"):
                    lines.append(f";; {entry_name} = {entry_value}")
                else:
                    try:
                        int(entry_value, 0)
                    except ValueError:
                        lines.append(f";; {entry_name} = {entry_value}")
                    else:
                        lines.append(f"(defconstant +{c_identifier_to_lisp(entry_name)}+ {entry_value})")
        else:
            lines.append(f"(cffi:defcenum {type_info['lisp_name']}")
            lines.extend(f"  (:{c_identifier_to_lisp(entry_name)} {entry_value})" for entry_name, entry_value in type_info["numeric_enum_entries"])
            lines.append("  )")
    return lines


def emit_public_wrapper(function: dict) -> list[str]:
    auto_wrap = can_auto_wrap(function)
    signature = (
        [parameter for parameter in function["parameters"] if parameter_mode(function, parameter) != "out"]
        if auto_wrap
        else list(function["parameters"])
    )
    lines = [f"(defun {function['public_lisp_name']} ({' '.join(parameter['lisp_name'] for parameter in signature)})"]
    if not auto_wrap:
        if function["return_spec"] == "daq-err-code":
            lines.append(f'  (%check-error {emit_call(function["raw_lisp_name"], (parameter["lisp_name"] for parameter in function["parameters"]))} "{function["c_name"]}")')
            lines.append("  nil)")
        elif function["return_spec"] == ":void":
            lines.append(f'  {emit_call(function["raw_lisp_name"], (parameter["lisp_name"] for parameter in function["parameters"]))}')
            lines.append("  nil)")
        else:
            lines.append(f'  {emit_call(function["raw_lisp_name"], (parameter["lisp_name"] for parameter in function["parameters"]))})')
        return lines
    out_parameters = [parameter for parameter in function["parameters"] if parameter_mode(function, parameter) != "in"]
    slot_names = {parameter["lisp_name"]: f'{parameter["lisp_name"]}-slot' for parameter in out_parameters}
    indent = "  "
    for parameter in out_parameters:
        lines.append(f"{indent}(cffi:with-foreign-object ({slot_names[parameter['lisp_name']]} '{parameter['pointee_cffi_spec']})")
        indent += "  "
    for parameter in out_parameters:
        if parameter_mode(function, parameter) == "in-out":
            lines.append(f"{indent}(setf (cffi:mem-ref {slot_names[parameter['lisp_name']]} '{parameter['pointee_cffi_spec']}) {parameter['lisp_name']})")
    call_arguments = [parameter["lisp_name"] if parameter_mode(function, parameter) == "in" else slot_names[parameter["lisp_name"]] for parameter in function["parameters"]]
    if function["return_spec"] == "daq-err-code":
        lines.append(f'{indent}(%check-error {emit_call(function["raw_lisp_name"], call_arguments)} "{function["c_name"]}")')
    elif function["return_spec"] != ":void":
        lines.append(f'{indent}(let ((result {emit_call(function["raw_lisp_name"], call_arguments)}))')
        indent += "  "
    else:
        lines.append(f'{indent}{emit_call(function["raw_lisp_name"], call_arguments)}')
    result_forms = [f"(cffi:mem-ref {slot_names[parameter['lisp_name']]} '{parameter['pointee_cffi_spec']})" for parameter in out_parameters]
    if function["return_spec"] in {"daq-err-code", ":void"}:
        result = "nil" if not result_forms else result_forms[0] if len(result_forms) == 1 else f"(values {' '.join(result_forms)})"
        lines.append(f"{indent}{result}")
    else:
        result = "result" if not result_forms else f"(values result {' '.join(result_forms)})"
        lines.append(f"{indent}{result}")
        indent = indent[:-2]
        lines.append(f"{indent})")
    for _ in out_parameters:
        indent = indent[:-2]
        lines.append(f"{indent})")
    lines.append(")")
    return lines


def emit_function_section(functions: list[dict], skipped: list[tuple[str, str]]) -> list[str]:
    lines = ["", ";;; Functions"]
    for function in functions:
        lines.extend(["", f'(cffi:defcfun ("{function["c_name"]}" {function["raw_lisp_name"]}) {function["return_spec"]}'])
        if function["parameters"]:
            lines.extend(f'  ({parameter["lisp_name"]} {parameter["cffi_spec"]})' for parameter in function["parameters"])
        lines.extend(["  )", ""])
        lines.extend(emit_public_wrapper(function))
    lines.extend(["", ";;; Public wrapper exports", "(export '("])
    lines.extend(f"  {function['public_lisp_name']}" for function in functions)
    lines.append("  ))")
    if skipped:
        lines.extend(["", ";;; Skipped functions"])
        lines.extend(f";; {name}: {reason}" for name, reason in skipped)
    return lines


def generate_low_level_bindings(include_dir: Path) -> str:
    types = build_types(parse_records(include_dir))
    functions, skipped = build_functions(parse_records(include_dir), types)
    return "\n".join(
        [
            ";;; This file is autogenerated by tools/generate_low_level_bindings.py.",
            ";;; Do not edit it by hand.",
            "",
            "(in-package #:opendaq.low-level)",
            "",
            *emit_type_section(types),
            *emit_function_section(functions, skipped),
            "",
        ]
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate low-level Common Lisp CFFI bindings from openDAQ C headers.")
    parser.add_argument("--include-dir", type=Path, required=True, help="Directory containing the openDAQ C headers.")
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "generated" / "low-level-bindings.lisp", help="Output Lisp file.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        generated = generate_low_level_bindings(args.include_dir)
    except Exception as exc:  # noqa: BLE001
        print(f"error: {exc}", file=sys.stderr)
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(generated)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
