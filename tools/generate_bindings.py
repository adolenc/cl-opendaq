#!/usr/bin/env python3

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


COMMENT_RE = re.compile(r"/\*.*?\*/|//[^\n]*", re.S)
PREPROCESSOR_RE = re.compile(r"^\s*#.*$", re.M)
DEFINE_RE = re.compile(
    r"^\s*#define\s+(?P<name>[A-Za-z_]\w*)\s+(?P<value>\(?[-+]?0[xX][0-9A-Fa-f]+|\(?[-+]?\d+\)?)\s*$",
    re.M,
)
OPAQUE_STRUCT_RE = re.compile(r"typedef\s+struct\s+(daq\w+)\s+(daq\w+)\s*;", re.S)
CONCRETE_STRUCT_RE = re.compile(
    r"typedef\s+struct\s+(daq\w+)\s*\{(?P<body>.*?)\}\s*(daq\w+)\s*;", re.S
)
ENUM_RE = re.compile(
    r"typedef\s+enum\s+(daq\w+)\s*\{(?P<body>.*?)\}\s*(daq\w+)\s*;", re.S
)
FUNCTION_POINTER_RE = re.compile(
    r"typedef\s+(?P<ret>[^;()]+?)\(\s*\*\s*(?P<name>daq\w+)\s*\)\s*\((?P<args>.*?)\)\s*;",
    re.S,
)
SIMPLE_TYPEDEF_RE = re.compile(
    r"typedef\s+(?!struct\b)(?!enum\b)(?P<base>[^;()]+?)\s+(?P<name>daq\w+)\s*;"
)
FUNCTION_RE = re.compile(
    r"(?P<ret>[A-Za-z_][A-Za-z0-9_\s\*]*?)\s+EXPORTED\s+"
    r"(?P<name>daq\w+)\s*\((?P<args>[^;]*)\)\s*;",
    re.S,
)

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

IGNORED_FILENAMES = {"copendaq_private.h"}


@dataclass(frozen=True)
class TypeInfo:
    c_name: str
    lisp_name: str
    kind: str
    cffi_spec: str
    pointer_like: bool = False
    fields: tuple[tuple[str, str], ...] = ()
    enum_entries: tuple[tuple[str, str], ...] = ()
    numeric_enum_entries: tuple[tuple[str, int], ...] = ()
    enum_has_duplicates: bool = False
    enum_has_unsupported_values: bool = False


@dataclass(frozen=True)
class ParameterInfo:
    c_name: str
    lisp_name: str
    cffi_spec: str
    base_type: str
    base_lisp_name: str
    base_kind: str | None
    pointer_depth: int
    pointer_like: bool = False
    pointee_cffi_spec: str | None = None
    pointee_kind: str | None = None


@dataclass(frozen=True)
class FunctionInfo:
    c_name: str
    raw_lisp_name: str
    public_lisp_name: str
    return_spec: str
    parameters: tuple[ParameterInfo, ...]


@dataclass(frozen=True)
class SkippedFunctionInfo:
    c_name: str
    reason: str


RAW_BUFFER_PARAMETER_NAMES = {
    "blocks",
    "data",
    "data-blocks",
    "domain",
    "domain-blocks",
    "samples",
    "values",
}

IN_OUT_PARAMETER_OVERRIDES: dict[str, dict[str, str]] = {
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
    tokens: list[str] = []
    for chunk in name.split("_"):
        tokens.extend(
            match.group(0).lower()
            for match in re.finditer(
                r"[A-Z]+(?=[A-Z][a-z]|[0-9]|\b)|[A-Z]?[a-z]+|[a-z]+|[0-9]+",
                chunk,
            )
        )
    return "-".join(token for token in tokens if token)


def strip_daq_prefix(name: str) -> str:
    if name.startswith("daq") and len(name) > 3 and name[3].isupper():
        return name[3:]
    return name


def c_function_to_public_lisp(name: str) -> str:
    receiver, separator, method = name.partition("_")
    public_receiver = c_identifier_to_lisp(strip_daq_prefix(receiver))
    if not separator:
        return public_receiver or c_identifier_to_lisp(name)
    public_method = c_identifier_to_lisp(method)
    if public_receiver and public_method:
        return f"{public_receiver}/{public_method}"
    return public_receiver or public_method or c_identifier_to_lisp(name)


def strip_comments(text: str) -> str:
    return COMMENT_RE.sub("", text)


def strip_comments_and_preprocessor(text: str) -> str:
    return PREPROCESSOR_RE.sub("", strip_comments(text))


def scan_numeric_defines(text: str) -> dict[str, int]:
    defines: dict[str, int] = {}
    for match in DEFINE_RE.finditer(strip_comments(text)):
        value_text = match.group("value").strip()
        if value_text.startswith("(") and value_text.endswith(")"):
            value_text = value_text[1:-1].strip()
        try:
            defines[match.group("name")] = int(value_text, 0)
        except ValueError:
            continue
    return defines


def split_type_and_name(declaration: str) -> tuple[str, str]:
    declaration = " ".join(declaration.split())
    match = re.match(r"(?P<type>.+?)(?P<name>[A-Za-z_]\w*)$", declaration)
    if not match:
        raise ValueError(f"Unable to split declaration: {declaration}")
    return match.group("type").strip(), match.group("name")


def parse_type_parts(type_spec: str) -> tuple[str, int]:
    normalized = " ".join(type_spec.replace("*", " * ").split())
    tokens = [token for token in normalized.split() if token not in {"const", "volatile", "restrict"}]
    pointer_depth = tokens.count("*")
    base_tokens = [token for token in tokens if token != "*"]
    if not base_tokens:
        raise ValueError(f"Unable to parse C type: {type_spec}")
    return " ".join(base_tokens), pointer_depth


def wrap_pointer(type_spec: str, depth: int) -> str:
    spec = type_spec
    for _ in range(depth):
        spec = f"(:pointer {spec})"
    return spec


def parse_field_list(body: str) -> tuple[tuple[str, str], ...]:
    fields: list[tuple[str, str]] = []
    for raw_field in body.split(";"):
        field = raw_field.strip()
        if not field:
            continue
        type_part, name = split_type_and_name(field)
        base_type, pointer_depth = parse_type_parts(type_part)
        if base_type not in BUILTIN_TYPE_MAP:
            raise ValueError(f"Unsupported struct field type: {base_type}")
        fields.append((c_identifier_to_lisp(name), wrap_pointer(BUILTIN_TYPE_MAP[base_type], pointer_depth)))
    return tuple(fields)


def parse_enum_entries(
    body: str,
    defines: dict[str, int],
) -> tuple[tuple[tuple[str, str], ...], tuple[tuple[str, int], ...], bool, bool]:
    entries: list[tuple[str, str]] = []
    numeric_entries: list[tuple[str, int]] = []
    used_values: set[int] = set()
    has_duplicates = False
    has_unsupported_values = False
    current_value: int | None = -1

    for raw_entry in body.split(","):
        entry = raw_entry.strip()
        if not entry:
            continue
        if "=" in entry:
            name, value_text = [part.strip() for part in entry.split("=", 1)]
            try:
                current_value = int(value_text, 0)
                numeric_entries.append((name, current_value))
            except ValueError:
                if value_text in defines:
                    current_value = defines[value_text]
                    numeric_entries.append((name, current_value))
                else:
                    has_unsupported_values = True
                    current_value = None
            entries.append((name, value_text))
        else:
            name = entry
            if current_value is None:
                has_unsupported_values = True
                entries.append((name, "<implicit-after-unsupported>"))
                continue
            current_value += 1
            entries.append((name, str(current_value)))
            numeric_entries.append((name, current_value))

        if numeric_entries and numeric_entries[-1][0] == name:
            if numeric_entries[-1][1] in used_values:
                has_duplicates = True
            used_values.add(numeric_entries[-1][1])

    return tuple(entries), tuple(numeric_entries), has_duplicates, has_unsupported_values


def parse_parameters(parameter_text: str, types: dict[str, TypeInfo]) -> tuple[ParameterInfo, ...]:
    normalized = " ".join(parameter_text.split())
    if normalized == "void" or not normalized:
        return ()

    parameters: list[ParameterInfo] = []
    for index, raw_parameter in enumerate(parameter_text.split(","), start=1):
        parameter = raw_parameter.strip()
        type_part, name = split_type_and_name(parameter)
        base_type, pointer_depth = parse_type_parts(type_part)
        ensure_supported_signature_type(base_type, pointer_depth, types)
        lisp_spec = resolve_cffi_type(base_type, pointer_depth, types)
        base_info = types.get(base_type)
        pointee_cffi_spec = None
        pointee_kind = None
        if pointer_depth > 0:
            pointee_cffi_spec = resolve_cffi_type(base_type, pointer_depth - 1, types)
            if base_info:
                pointee_kind = base_info.kind
            elif base_type in BUILTIN_TYPE_MAP:
                pointee_kind = "builtin"
        parameters.append(
            ParameterInfo(
                c_name=name or f"arg{index}",
                lisp_name=c_identifier_to_lisp(name or f"arg{index}"),
                cffi_spec=lisp_spec,
                base_type=base_type,
                base_lisp_name=base_info.lisp_name if base_info else BUILTIN_TYPE_MAP[base_type],
                base_kind=base_info.kind if base_info else "builtin",
                pointer_depth=pointer_depth,
                pointer_like=base_info.pointer_like if base_info else False,
                pointee_cffi_spec=pointee_cffi_spec,
                pointee_kind=pointee_kind,
            )
        )
    return tuple(parameters)


def resolve_cffi_type(base_type: str, pointer_depth: int, types: dict[str, TypeInfo]) -> str:
    if base_type in types:
        type_info = types[base_type]
        if type_info.pointer_like:
            if pointer_depth == 0:
                return type_info.lisp_name
            return wrap_pointer(type_info.lisp_name, pointer_depth - 1)
        return wrap_pointer(type_info.lisp_name, pointer_depth)

    if base_type in BUILTIN_TYPE_MAP:
        builtin = BUILTIN_TYPE_MAP[base_type]
        if builtin == ":void" and pointer_depth > 0:
            return wrap_pointer(":pointer", pointer_depth - 1)
        return wrap_pointer(builtin, pointer_depth)

    raise ValueError(f"Unsupported C type: {base_type}")


def ensure_supported_signature_type(base_type: str, pointer_depth: int, types: dict[str, TypeInfo]) -> None:
    type_info = types.get(base_type)
    if type_info and type_info.kind == "struct" and pointer_depth == 0:
        raise ValueError(f"by-value struct parameters are not supported yet ({base_type})")


def collect_headers(include_dir: Path) -> list[Path]:
    headers = []
    for path in sorted(include_dir.rglob("*.h")):
        if path.name in IGNORED_FILENAMES or "private" in path.parts:
            continue
        headers.append(path)
    return headers


def scan_types(headers: Iterable[Path]) -> dict[str, TypeInfo]:
    types: dict[str, TypeInfo] = {}
    pending_aliases: list[tuple[str, str, int, Path]] = []

    for header in headers:
        raw_text = header.read_text()
        text = strip_comments_and_preprocessor(raw_text)
        defines = scan_numeric_defines(raw_text)

        for match in CONCRETE_STRUCT_RE.finditer(text):
            c_name = match.group(3)
            types.setdefault(
                c_name,
                TypeInfo(
                    c_name=c_name,
                    lisp_name=c_identifier_to_lisp(c_name),
                    kind="struct",
                    cffi_spec=f"(:struct {c_identifier_to_lisp(c_name)})",
                    fields=parse_field_list(match.group("body")),
                ),
            )

        for match in ENUM_RE.finditer(text):
            c_name = match.group(3)
            entries, numeric_entries, has_duplicates, has_unsupported_values = parse_enum_entries(
                match.group("body"), defines
            )
            lisp_name = c_identifier_to_lisp(c_name)
            types.setdefault(
                c_name,
                TypeInfo(
                    c_name=c_name,
                    lisp_name=lisp_name,
                    kind="enum",
                    cffi_spec=lisp_name if not has_duplicates else "daq-enum-type",
                    enum_entries=entries,
                    numeric_enum_entries=numeric_entries,
                    enum_has_duplicates=has_duplicates,
                    enum_has_unsupported_values=has_unsupported_values,
                ),
            )

        for match in OPAQUE_STRUCT_RE.finditer(text):
            c_name = match.group(2)
            types.setdefault(
                c_name,
                TypeInfo(
                    c_name=c_name,
                    lisp_name=c_identifier_to_lisp(c_name),
                    kind="opaque",
                    cffi_spec=":pointer",
                    pointer_like=True,
                ),
            )

        for match in FUNCTION_POINTER_RE.finditer(text):
            c_name = match.group("name")
            types.setdefault(
                c_name,
                TypeInfo(
                    c_name=c_name,
                    lisp_name=c_identifier_to_lisp(c_name),
                    kind="callback",
                    cffi_spec=":pointer",
                    pointer_like=True,
                ),
            )

        consumed_spans = [
            *[match.span() for match in CONCRETE_STRUCT_RE.finditer(text)],
            *[match.span() for match in ENUM_RE.finditer(text)],
            *[match.span() for match in OPAQUE_STRUCT_RE.finditer(text)],
            *[match.span() for match in FUNCTION_POINTER_RE.finditer(text)],
        ]
        mutable = list(text)
        for start, end in consumed_spans:
            for index in range(start, end):
                mutable[index] = " "
        text_without_complex_typedefs = "".join(mutable)

        for match in SIMPLE_TYPEDEF_RE.finditer(text_without_complex_typedefs):
            c_name = match.group("name")
            if c_name in types:
                continue
            base_type, pointer_depth = parse_type_parts(match.group("base"))
            pending_aliases.append((c_name, base_type, pointer_depth, header))

    while pending_aliases:
        unresolved: list[tuple[str, str, int, Path]] = []
        progress = False
        for c_name, base_type, pointer_depth, header in pending_aliases:
            lisp_name = c_identifier_to_lisp(c_name)
            if c_name == "daqBaseObject" or pointer_depth > 0:
                types[c_name] = TypeInfo(
                    c_name=c_name,
                    lisp_name=lisp_name,
                    kind="pointer-alias",
                    cffi_spec=":pointer",
                    pointer_like=True,
                )
                progress = True
                continue

            if base_type in BUILTIN_TYPE_MAP:
                types[c_name] = TypeInfo(
                    c_name=c_name,
                    lisp_name=lisp_name,
                    kind="alias",
                    cffi_spec=BUILTIN_TYPE_MAP[base_type],
                )
                progress = True
                continue

            if base_type in types:
                aliased = types[base_type]
                types[c_name] = TypeInfo(
                    c_name=c_name,
                    lisp_name=lisp_name,
                    kind="alias",
                    cffi_spec=aliased.lisp_name,
                    pointer_like=aliased.pointer_like,
                )
                progress = True
                continue

            unresolved.append((c_name, base_type, pointer_depth, header))

        if not progress:
            unresolved_text = ", ".join(
                f"{c_name} -> {base_type} ({header})"
                for c_name, base_type, _, header in unresolved[:10]
            )
            raise ValueError(f"Unsupported typedef base type(s): {unresolved_text}")
        pending_aliases = unresolved

    return types


def scan_functions(
    headers: Iterable[Path], types: dict[str, TypeInfo]
) -> tuple[list[FunctionInfo], list[SkippedFunctionInfo]]:
    functions: dict[str, FunctionInfo] = {}
    skipped: dict[str, SkippedFunctionInfo] = {}
    for header in headers:
        text = strip_comments_and_preprocessor(header.read_text())
        for match in FUNCTION_RE.finditer(text):
            c_name = match.group("name")
            if c_name in functions or c_name in skipped:
                continue
            return_type, return_pointer_depth = parse_type_parts(match.group("ret"))
            try:
                ensure_supported_signature_type(return_type, return_pointer_depth, types)
                functions[c_name] = FunctionInfo(
                    c_name=c_name,
                    raw_lisp_name="%" + c_identifier_to_lisp(c_name),
                    public_lisp_name=c_function_to_public_lisp(c_name),
                    return_spec=resolve_cffi_type(return_type, return_pointer_depth, types),
                    parameters=parse_parameters(match.group("args"), types),
                )
            except ValueError as exc:
                skipped[c_name] = SkippedFunctionInfo(c_name=c_name, reason=str(exc))
    return [functions[name] for name in sorted(functions)], [skipped[name] for name in sorted(skipped)]


def emit_type_section(types: dict[str, TypeInfo]) -> list[str]:
    lines = [";;; Types"]
    emitted_aliases: set[str] = set()

    for type_info in sorted(types.values(), key=lambda item: item.lisp_name):
        if type_info.kind in {"alias", "pointer-alias", "opaque", "callback"}:
            if type_info.lisp_name in emitted_aliases:
                continue
            lines.append(f"(cffi:defctype {type_info.lisp_name} {type_info.cffi_spec})")
            emitted_aliases.add(type_info.lisp_name)

    for type_info in sorted(types.values(), key=lambda item: item.lisp_name):
        if type_info.kind != "struct":
            continue
        lines.append("")
        lines.append(f"(cffi:defcstruct {type_info.lisp_name}")
        for field_name, field_type in type_info.fields:
            lines.append(f"  ({field_name} {field_type})")
        lines.append("  )")
        lines.append(
            f"(cffi:defctype {type_info.lisp_name} (:struct {type_info.lisp_name}))"
        )

    for type_info in sorted(types.values(), key=lambda item: item.lisp_name):
        if type_info.kind != "enum":
            continue
        lines.append("")
        if type_info.enum_has_duplicates or type_info.enum_has_unsupported_values:
            lines.append(
                f";; {type_info.c_name} uses duplicate or unsupported enum values; emit a raw enum alias plus constants/comments."
            )
            lines.append(f"(cffi:defctype {type_info.lisp_name} daq-enum-type)")
            for entry_name, entry_value in type_info.enum_entries:
                if entry_value.startswith("<"):
                    lines.append(
                        f";; {entry_name} = {entry_value}"
                    )
                else:
                    try:
                        int(entry_value, 0)
                    except ValueError:
                        lines.append(f";; {entry_name} = {entry_value}")
                    else:
                        lines.append(
                            f"(defconstant +{c_identifier_to_lisp(entry_name)}+ {entry_value})"
                        )
        else:
            lines.append(f"(cffi:defcenum {type_info.lisp_name}")
            for entry_name, entry_value in type_info.numeric_enum_entries:
                lines.append(f"  (:{c_identifier_to_lisp(entry_name)} {entry_value})")
            lines.append("  )")

    return lines


def parameter_mode(function: FunctionInfo, parameter: ParameterInfo) -> str:
    override = IN_OUT_PARAMETER_OVERRIDES.get(function.c_name, {}).get(parameter.lisp_name)
    if override:
        return override
    if parameter.pointer_depth == 0:
        return "in"
    if parameter.pointer_depth == 1 and (
        parameter.base_kind in {"opaque", "callback"} or parameter.base_type == "daqBaseObject"
    ):
        return "in"
    if parameter.base_type == "void":
        return "in"
    if parameter.lisp_name in RAW_BUFFER_PARAMETER_NAMES:
        return "in"
    return "out"


def can_auto_wrap(function: FunctionInfo) -> bool:
    for parameter in function.parameters:
        mode = parameter_mode(function, parameter)
        if mode == "in":
            continue
        if parameter.pointee_cffi_spec is None or parameter.pointee_kind == "struct":
            return False
    return True


def emit_call(function_name: str, arguments: Iterable[str]) -> str:
    args = " ".join(arguments)
    if args:
        return f"({function_name} {args})"
    return f"({function_name})"


def emit_public_wrapper(function: FunctionInfo) -> list[str]:
    auto_wrap = can_auto_wrap(function)
    signature_parameters = (
        [parameter for parameter in function.parameters if parameter_mode(function, parameter) != "out"]
        if auto_wrap
        else list(function.parameters)
    )
    arguments = " ".join(parameter.lisp_name for parameter in signature_parameters)
    lines = [f"(defun {function.public_lisp_name} ({arguments})"]
    lines.append("  (ensure-opendaq-loaded)")

    if not auto_wrap:
        if function.return_spec == "daq-err-code":
            lines.append(
                f'  (%check-error {emit_call(function.raw_lisp_name, (parameter.lisp_name for parameter in function.parameters))} "{function.c_name}")'
            )
            lines.append("  nil)")
        elif function.return_spec == ":void":
            lines.append(
                f"  {emit_call(function.raw_lisp_name, (parameter.lisp_name for parameter in function.parameters))}"
            )
            lines.append("  nil)")
        else:
            lines.append(
                f"  {emit_call(function.raw_lisp_name, (parameter.lisp_name for parameter in function.parameters))})"
            )
        return lines

    out_parameters = [
        parameter for parameter in function.parameters if parameter_mode(function, parameter) != "in"
    ]
    slot_names = {parameter.lisp_name: f"{parameter.lisp_name}-slot" for parameter in out_parameters}

    indent = "  "
    for parameter in out_parameters:
        lines.append(
            f"{indent}(cffi:with-foreign-object ({slot_names[parameter.lisp_name]} '{parameter.pointee_cffi_spec})"
        )
        indent += "  "

    for parameter in out_parameters:
        if parameter_mode(function, parameter) == "in-out":
            lines.append(
                f"{indent}(setf (cffi:mem-ref {slot_names[parameter.lisp_name]} '{parameter.pointee_cffi_spec}) {parameter.lisp_name})"
            )

    call_arguments: list[str] = []
    for parameter in function.parameters:
        mode = parameter_mode(function, parameter)
        if mode == "in":
            call_arguments.append(parameter.lisp_name)
        else:
            call_arguments.append(slot_names[parameter.lisp_name])
    joined_call_arguments = " ".join(call_arguments)

    if function.return_spec == "daq-err-code":
        lines.append(
            f'{indent}(%check-error {emit_call(function.raw_lisp_name, call_arguments)} "{function.c_name}")'
        )
    elif function.return_spec != ":void":
        lines.append(f"{indent}(let ((result {emit_call(function.raw_lisp_name, call_arguments)}))")
        indent += "  "
    else:
        lines.append(f"{indent}{emit_call(function.raw_lisp_name, call_arguments)}")

    result_forms = [
        f"(cffi:mem-ref {slot_names[parameter.lisp_name]} '{parameter.pointee_cffi_spec})"
        for parameter in out_parameters
    ]

    if function.return_spec == "daq-err-code":
        if not result_forms:
            lines.append(f"{indent}nil")
        elif len(result_forms) == 1:
            lines.append(f"{indent}{result_forms[0]}")
        else:
            lines.append(f"{indent}(values {' '.join(result_forms)})")
    elif function.return_spec == ":void":
        if not result_forms:
            lines.append(f"{indent}nil")
        elif len(result_forms) == 1:
            lines.append(f"{indent}{result_forms[0]}")
        else:
            lines.append(f"{indent}(values {' '.join(result_forms)})")
    else:
        if not result_forms:
            lines.append(f"{indent}result")
        else:
            lines.append(f"{indent}(values result {' '.join(result_forms)})")
        indent = indent[:-2]
        lines.append(f"{indent})")

    for _ in out_parameters:
        indent = indent[:-2]
        lines.append(f"{indent})")

    lines.append(")")
    return lines


def emit_function_section(
    functions: list[FunctionInfo], skipped_functions: list[SkippedFunctionInfo]
) -> list[str]:
    lines = ["", ";;; Functions"]
    for function in functions:
        lines.append("")
        lines.append(
            f'(cffi:defcfun ("{function.c_name}" {function.raw_lisp_name}) {function.return_spec}'
        )
        if function.parameters:
            for parameter in function.parameters:
                lines.append(f"  ({parameter.lisp_name} {parameter.cffi_spec})")
            lines.append("  )")
        else:
            lines.append("  )")
        lines.append("")
        lines.extend(emit_public_wrapper(function))
    lines.append("")
    lines.append(";;; Public wrapper exports")
    lines.append("(export '(")
    for function in functions:
        lines.append(f"  {function.public_lisp_name}")
    lines.append("  ))")
    if skipped_functions:
        lines.append("")
        lines.append(";;; Skipped functions")
        for skipped in skipped_functions:
            lines.append(f";; {skipped.c_name}: {skipped.reason}")
    return lines


def generate_bindings(include_dir: Path) -> str:
    headers = collect_headers(include_dir)
    if not headers:
        raise ValueError(f"No headers found under {include_dir}")

    types = scan_types(headers)
    functions, skipped_functions = scan_functions(headers, types)

    lines = [
        ";;; This file is autogenerated by tools/generate_bindings.py.",
        ";;; Do not edit it by hand.",
        "",
        "(in-package #:opendaq)",
        "",
    ]
    lines.extend(emit_type_section(types))
    lines.extend(emit_function_section(functions, skipped_functions))
    lines.append("")
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate low-level Common Lisp CFFI bindings from openDAQ C headers."
    )
    parser.add_argument(
        "--include-dir",
        type=Path,
        default=Path(__file__).resolve().parents[2] / "bindings" / "c" / "include",
        help="Directory containing the openDAQ C headers.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "generated" / "bindings.lisp",
        help="Output Lisp file.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        generated = generate_bindings(args.include_dir.resolve())
    except Exception as exc:  # noqa: BLE001
        print(f"error: {exc}", file=sys.stderr)
        return 1

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(generated)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
