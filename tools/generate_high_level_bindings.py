#!/usr/bin/env python3

from __future__ import annotations

import argparse
import re
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

LOW_LEVEL_PACKAGE = "opendaq"
DEFAULT_INCLUDE_DIR = Path(__file__).resolve().parents[1] / "include"


@dataclass(frozen=True)
class ClassOverride:
    constructor_name: str | None = None
    constructor_defaults: tuple[tuple[str, str], ...] = ()


@dataclass(frozen=True)
class FunctionOverride:
    specializer: str | None = None
    optional_defaults: tuple[tuple[str, str], ...] = ()


@dataclass(frozen=True)
class ClassSpec:
    name: str
    constructor: FunctionInfo | None = None
    constructor_defaults: tuple[tuple[str, str], ...] = ()


@dataclass(frozen=True)
class MethodSpec:
    function: FunctionInfo
    kind: str
    name: str
    specializer: str
    optional_defaults: tuple[tuple[str, str], ...] = ()

CLASS_NAME_OVERRIDES = {
    "boolean": "daq-boolean",
    "function": "daq-function",
    "integer": "daq-integer",
    "list": "object-list",
    "number": "daq-number",
    "string": "daq-string-object",
    "type": "daq-type",
}

# Map of (function_public_lisp_name, output_param_c_name) -> element-type class name.
# The C++ headers carry [elementType(param, Type)] annotations, but the C
# headers that the generator actually parses have no such info.  This dict
# bridges the gap until the generator learns to read the C++ headers directly.
LIST_ELEMENT_TYPES: dict[tuple[str, str], str] = {
    # device.h
    ("device/get-available-devices", "availableDevices"): "device-info",
    ("device/get-devices", "devices"): "device",
    ("device/get-function-blocks", "functionBlocks"): "function-block",
    ("device/get-signals", "signals"): "signal",
    ("device/get-signals-recursive", "signals"): "signal",
    ("device/get-channels", "channels"): "channel",
    ("device/get-channels-recursive", "channels"): "channel",
    ("device/get-servers", "servers"): "server",
    ("device/get-log-file-infos", "logFileInfos"): "log-file-info",
    ("device/get-custom-components", "customComponents"): "component",
    # module.h
    ("module/get-available-devices", "availableDevices"): "device-info",
    # module_manager_utils.h
    ("module-manager-utils/get-available-devices", "availableDevices"): "device-info",
    # function_block.h
    ("function-block/get-signals", "signals"): "signal",
    ("function-block/get-signals-recursive", "signals"): "signal",
    # server.h
    ("server/get-signals", "signals"): "signal",
}

CLASS_OVERRIDES = {
    "instance": ClassOverride(
        constructor_name="instance/create-instance-from-builder",
        constructor_defaults=(
            (
                "builder",
                "(let ((builder (make-instance 'instance-builder))) "
                "(setf (module-path builder) (native-library-directory)) "
                "builder)",
            ),
        ),
    ),
    "stream-reader": ClassOverride(
        constructor_defaults=(
            ("value-read-type", "opendaq::+daq-sample-type-float-64+"),
            ("domain-read-type", "opendaq::+daq-sample-type-int-64+"),
            ("mode", ":daq-read-mode-scaled"),
            ("timeout-type", ":daq-read-timeout-type-any"),
        )
    ),
}

RESERVED_METHOD_NAMES = {"read-samples"}

FUNCTION_OVERRIDES = {
    "instance-builder/enable-standard-providers": FunctionOverride(
        optional_defaults=(("flag", "t"),)
    ),
    "device/add-device": FunctionOverride(optional_defaults=(("config", "nil"),)),
    "device/get-signals": FunctionOverride(optional_defaults=(("search-filter", "nil"),)),
    "device/get-signals-recursive": FunctionOverride(
        optional_defaults=(("search-filter", "nil"),)
    ),
    "server/get-signals": FunctionOverride(
        optional_defaults=(("search-filter", "nil"),),
    ),
    "function-block/get-signals": FunctionOverride(
        optional_defaults=(("search-filter", "nil"),),
    ),
    "function-block/get-signals-recursive": FunctionOverride(
        optional_defaults=(("search-filter", "nil"),),
    ),
}


def canonical_class_name(name: str) -> str:
    return CLASS_NAME_OVERRIDES.get(name, name)


def class_name_for_type(type_name: str) -> str | None:
    if type_name.startswith("daq-"):
        return canonical_class_name(type_name[4:])
    return None


def receiver_name(function: FunctionInfo) -> str:
    return canonical_class_name(function.public_lisp_name.partition("/")[0])


def method_name(function: FunctionInfo) -> str:
    return function.public_lisp_name.partition("/")[2]


def call_parameters(function: FunctionInfo) -> tuple[ParameterInfo, ...]:
    return tuple(
        parameter
        for parameter in function.parameters
        if parameter_mode(function, parameter) != "out"
    )


def output_parameters(function: FunctionInfo) -> tuple[ParameterInfo, ...]:
    return tuple(
        parameter
        for parameter in function.parameters
        if parameter_mode(function, parameter) != "in"
    )


def constructor_parameters(function: FunctionInfo) -> tuple[ParameterInfo, ...]:
    return tuple(
        parameter
        for parameter in function.parameters
        if parameter.lisp_name != "obj" and parameter_mode(function, parameter) != "out"
    )


def classify_function(function: FunctionInfo) -> str:
    stem = method_name(function)
    if stem.startswith("create-"):
        outputs = output_parameters(function)
        if (
            not uses_instance_receiver(function)
            and len(outputs) == 1
            and outputs[0].lisp_name == "obj"
        ):
            return "constructor"
        return "method"
    if stem.startswith("get-"):
        return "reader"
    if stem.startswith("set-"):
        if not method_parameters(function):
            return "method"
        return "writer"
    return "method"


HIERARCHY_CACHE: dict[str, str] | None = None


def _scan_interface_hierarchy(cpp_root: Path) -> dict[str, str]:
    """Extract class parent relationships from DECLARE_OPENDAQ_INTERFACE macros.

    Returns a mapping from child lisp class name to parent lisp class name.
    E.g. ``{"instance": "device", "device": "folder", ...}``.
    """
    def to_lisp_name(camel: str) -> str:
        """Convert ``CamelCase`` to ``hyphenated-case``, then apply overrides."""
        hyphenated = re.sub(r"([a-z])([A-Z])", r"\1-\2", camel).lower()
        return CLASS_NAME_OVERRIDES.get(hyphenated, hyphenated)

    hierarchy: dict[str, str] = {}
    rx = re.compile(r"DECLARE_OPENDAQ_INTERFACE\s*\(\s*I(\w+)\s*,\s*I(\w+)\s*\)")
    for header in sorted(cpp_root.rglob("*.h")):
        if "gmock" in str(header) or "test" in str(header):
            continue
        try:
            text = header.read_text(errors="ignore")
        except OSError:
            continue
        for match in rx.finditer(text):
            child = to_lisp_name(match.group(1))
            parent = to_lisp_name(match.group(2))
            hierarchy[child] = parent
    return hierarchy


def class_parent(class_name: str, cpp_root: Path | None = None) -> str:
    """Return the parent class for *class_name*, or ``"managed-object"``."""
    global HIERARCHY_CACHE
    if HIERARCHY_CACHE is None:
        if cpp_root is None:
            cpp_root = DEFAULT_INCLUDE_DIR.parent / "tmp" / "openDAQ" / "core"
        HIERARCHY_CACHE = _scan_interface_hierarchy(cpp_root)
    if class_name == "managed-object":
        return "standard-object"
    return HIERARCHY_CACHE.get(class_name, "managed-object")


def ancestor_chain(class_name: str) -> list[str]:
    """Return the ancestor chain from *class_name* up to and including ``"managed-object"``."""
    chain = [class_name]
    current = class_name
    while current != "managed-object":
        current = class_parent(current)
        chain.append(current)
    return chain


def lowest_common_ancestor(class_names: set[str]) -> str:
    """Find the lowest (most specific) common ancestor class of *class_names*."""
    if len(class_names) == 1:
        return next(iter(class_names))
    chains = [list(reversed(ancestor_chain(n))) for n in class_names]
    lca = "managed-object"
    for idx in range(len(chains[0])):
        ancestor = chains[0][idx]
        if any(idx >= len(c) or c[idx] != ancestor for c in chains[1:]):
            break
        lca = ancestor
    return lca


def _emit_polymorphic_bridge(
    method_name: str, specs: list[MethodSpec], lca: str
) -> list[str] | None:
    """Emit a bridge defmethod on *lca* that tries each sibling's low-level call.

    Only works for methods with no outputs beyond the return value.
    Returns a list of Lisp source lines, or ``None`` if a bridge cannot be generated.
    """
    # Use the first spec as the template for the parameter list.
    template = specs[0]
    parameters = method_parameters(template.function)
    defaults = {name: value for name, value in template.optional_defaults}

    # Build the lambda list.
    lambda_parts = [f"(object {lca})"]
    for p in parameters:
        if p.lisp_name in defaults:
            lambda_parts.append(f"&optional ({p.lisp_name} {defaults[p.lisp_name]})")
        else:
            lambda_parts.append(p.lisp_name)
    lambda_list = " ".join(lambda_parts)

    lines = [f"(defmethod {method_name} ({lambda_list})"]

    # Emit a chain of handler-case forms: try each sibling, catching errors.
    inner_form: str | None = None
    for spec in specs:
        func = spec.function
        call_args = ["(%require-live-pointer object)"]
        for p in method_parameters(func):
            arg_name = f"coerced-{p.lisp_name}" if coerce_category(p) is not None else p.lisp_name
            call_args.append(arg_name)
        call_form = f"({LOW_LEVEL_PACKAGE}:{func.public_lisp_name} {' '.join(call_args)})"

        if func.return_spec == "daq-err-code":
            # Returns via output parameter — not supported for bridges yet
            return None

        if inner_form is None:
            inner_form = call_form
        else:
            inner_form = f"(handler-case {call_form} (error () {inner_form}))"

    # Generate the coercion let-bindings for all parameters
    coercion_bindings = []
    for p in parameters:
        cat = coerce_category(p)
        if cat is not None:
            coercion_bindings.append(f"(coerced-{p.lisp_name} ({cat} {p.lisp_name}))")

    if coercion_bindings:
        lines.append(f"  (let ({' '.join(coercion_bindings)})")
        lines.append(f"    {inner_form})")
    else:
        lines.append(f"  {inner_form}")
    lines.append("")

    return lines


def exposed_name(function: FunctionInfo, kind: str) -> str:
    stem = method_name(function)
    if kind in {"reader", "writer"}:
        return stem.partition("-")[2]
    return stem


def uses_instance_receiver(function: FunctionInfo) -> bool:
    parameters = call_parameters(function)
    return bool(parameters) and parameters[0].lisp_name == "self"


def method_parameters(function: FunctionInfo) -> tuple[ParameterInfo, ...]:
    parameters = call_parameters(function)
    if uses_instance_receiver(function):
        return parameters[1:]
    return parameters


def result_class_names(function: FunctionInfo) -> tuple[str, ...]:
    classes: list[str] = []
    for parameter in output_parameters(function):
        if parameter.base_lisp_name == "daq-string" or not parameter.pointer_like:
            continue
        class_name = class_name_for_type(parameter.base_lisp_name)
        if class_name is not None:
            classes.append(class_name)
    return tuple(classes)


def required_optional_counts(
    parameters: tuple[ParameterInfo, ...], optional_defaults: tuple[tuple[str, str], ...]
) -> tuple[int, int]:
    defaults = default_map(optional_defaults)
    required_count = len(parameters)
    for index, parameter in enumerate(parameters):
        if parameter.lisp_name in defaults:
            required_count = index
            break
    optional = parameters[required_count:]
    if optional and any(parameter.lisp_name not in defaults for parameter in optional):
        raise ValueError("Optional defaults must cover a trailing suffix of parameters.")
    return required_count, len(optional)


def generic_shape(
    parameters: tuple[ParameterInfo, ...], optional_defaults: tuple[tuple[str, str], ...]
) -> tuple[int, int]:
    return required_optional_counts(parameters, optional_defaults)


def writer_shape(
    parameters: tuple[ParameterInfo, ...], optional_defaults: tuple[tuple[str, str], ...]
) -> tuple[int, int]:
    if not parameters:
        raise ValueError("Writers require at least one value parameter.")
    accessor_parameters = parameters[:-1]
    return (2 + len(accessor_parameters), 0)


def qualified_name(function: FunctionInfo, kind: str) -> str:
    return f"{receiver_name(function)}-{exposed_name(function, kind)}"


def default_map(defaults: tuple[tuple[str, str], ...]) -> dict[str, str]:
    return dict(defaults)


def coerce_category(parameter: ParameterInfo) -> str | None:
    if parameter.base_lisp_name == "daq-string":
        return ":daq-string"
    if parameter.base_lisp_name == "daq-base-object":
        return ":daq-base-object"
    if parameter.base_lisp_name == "daq-bool":
        return ":daq-bool"
    if parameter.pointer_like and parameter.pointer_depth == 1:
        return ":managed-pointer"
    return None


def lambda_list(
    parameters: tuple[ParameterInfo, ...], optional_defaults: tuple[tuple[str, str], ...]
) -> str:
    defaults = default_map(optional_defaults)
    required_count = len(parameters)
    for index, parameter in enumerate(parameters):
        if parameter.lisp_name in defaults:
            required_count = index
            break

    non_optional = [parameter.lisp_name for parameter in parameters[:required_count]]
    optional = parameters[required_count:]
    if optional and any(parameter.lisp_name not in defaults for parameter in optional):
        raise ValueError("Optional defaults must cover a trailing suffix of parameters.")

    parts = list(non_optional)
    if optional:
        parts.append("&optional")
        parts.extend(
            f"({parameter.lisp_name} {defaults[parameter.lisp_name]})"
            for parameter in optional
        )
    return " ".join(parts)


def generic_lambda_list(
    parameters: tuple[ParameterInfo, ...], optional_defaults: tuple[tuple[str, str], ...]
) -> str:
    defaults = default_map(optional_defaults)
    required_count = len(parameters)
    for index, parameter in enumerate(parameters):
        if parameter.lisp_name in defaults:
            required_count = index
            break

    non_optional = [parameter.lisp_name for parameter in parameters[:required_count]]
    optional = parameters[required_count:]
    if optional and any(parameter.lisp_name not in defaults for parameter in optional):
        raise ValueError("Optional defaults must cover a trailing suffix of parameters.")

    parts = list(non_optional)
    if optional:
        parts.append("&optional")
        parts.extend(parameter.lisp_name for parameter in optional)
    return " ".join(parts)


def setter_lambda_list(
    parameters: tuple[ParameterInfo, ...], optional_defaults: tuple[tuple[str, str], ...]
) -> str:
    if optional_defaults:
        raise ValueError("Setf writers with optional arguments are not supported.")
    return " ".join(["new-value", "object", *(parameter.lisp_name for parameter in parameters)])


def constructor_lambda_lines(spec: ClassSpec) -> list[str]:
    """Emit an :after method that only handles constructor logic.

    Pointer adoption is handled generically by managed-object's :after,
    so classes only worry about their own native constructor call.
    """
    if spec.constructor is None:
        # No constructor; pointer adoption handled by managed-object :after.
        return [""]

    parameters = constructor_parameters(spec.constructor)
    defaults = default_map(spec.constructor_defaults)
    required = tuple(
        parameter for parameter in parameters if parameter.lisp_name not in defaults
    )
    ignored = tuple(
        parameter for parameter in parameters if parameter.lisp_name in defaults
    )
    lines = [
        f"(defmethod initialize-instance :after ((object {spec.name})",
        "                                       &key (pointer nil pointer-p)",
    ]
    for parameter in parameters:
        default = defaults.get(parameter.lisp_name, "nil")
        lines.append(
            f"                                            ({parameter.lisp_name} {default} {parameter.lisp_name}-p)"
        )
    ignore_clause = " ".join([f"{p.lisp_name}-p" for p in ignored])
    lines.append("                                       &allow-other-keys)")
    if ignore_clause:
        lines.append(f"  (declare (ignore pointer {ignore_clause}))")
    else:
        lines.append("  (declare (ignore pointer))")

    constructor_call = emit_coerced_call(
        parameters,
        [
            f"(%adopt-pointer object ({LOW_LEVEL_PACKAGE}:{spec.constructor.public_lisp_name}"
            + "".join(f" coerced-{parameter.lisp_name}" for parameter in parameters)
            + "))"
        ],
        indent="  ",
    )

    if required:
        required_checks = " ".join(f"{parameter.lisp_name}-p" for parameter in required)
        lines.append(f"  (when (and (not pointer-p) {required_checks})")
        lines.extend(constructor_call)
        lines.append("    ))")
    else:
        lines.append("  (unless pointer-p")
        lines.extend(constructor_call)
        lines.append("    ))")
    lines.append("")
    return lines


def emit_class_definition(spec: ClassSpec) -> list[str]:
    parent = class_parent(spec.name)
    slots = (
        [
            f"   (%{parameter.lisp_name}-initarg :initarg :{parameter.lisp_name} :initform nil)"
            for parameter in constructor_parameters(spec.constructor)
        ]
        if spec.constructor is not None
        else []
    )
    lines = [f"(defclass {spec.name} ({parent})", "  ("]
    lines.extend(slots)
    lines.extend(["   ))", "", ""])
    return lines


def emit_wrapper_constructor(spec: ClassSpec) -> list[str]:
    return [
        f"(defun wrap-{spec.name} (pointer)",
        "  (unless (or (null pointer) (cffi:null-pointer-p pointer))",
        f"    (make-instance '{spec.name} :pointer pointer)))",
        "",
    ]


def emit_coerced_call(
    parameters: tuple[ParameterInfo, ...], inner_lines: list[str], indent: str
) -> list[str]:
    lines: list[str] = []

    def recurse(index: int, current_indent: str) -> None:
        if index == len(parameters):
            lines.extend(indent_lines(inner_lines, current_indent))
            return

        parameter = parameters[index]
        category = coerce_category(parameter)
        if category is None:
            lines.append(
                f"{current_indent}(let ((coerced-{parameter.lisp_name} {parameter.lisp_name}))"
            )
            recurse(index + 1, current_indent + "  ")
            lines.append(f"{current_indent})")
            return

        lines.append(
            f"{current_indent}(multiple-value-bind (coerced-{parameter.lisp_name} cleanup-{parameter.lisp_name})"
        )
        lines.append(
            f"{current_indent}    (%coerce-argument {parameter.lisp_name} {category})"
        )
        lines.append(f"{current_indent}  (unwind-protect")
        recurse(index + 1, current_indent + "      ")
        lines.append(
            f"{current_indent}    (%cleanup-coerced-argument cleanup-{parameter.lisp_name})))"
        )

    recurse(0, indent)
    return lines


def value_expression(parameter: ParameterInfo, value_form: str, function_name: str = "") -> str:
    if parameter.base_lisp_name == "daq-string":
        return f"(%daq-string-to-lisp-and-release {value_form})"
    if parameter.base_lisp_name == "daq-bool":
        return f"(not (zerop {value_form}))"
    class_name = class_name_for_type(parameter.base_lisp_name)
    if parameter.pointer_like and class_name is not None:
        if function_name:
            element_type = LIST_ELEMENT_TYPES.get((function_name, parameter.c_name))
            if element_type is not None:
                return f"(as-list-of (wrap-{class_name} {value_form}) '{element_type})"
        return f"(wrap-{class_name} {value_form})"
    return value_form


def indent_lines(lines: list[str], prefix: str) -> list[str]:
    return [f"{prefix}{line}" if line else line for line in lines]


def lisp_type_reference(type_name: str) -> str:
    if type_name.startswith(":"):
        return type_name
    return f"{LOW_LEVEL_PACKAGE}::{type_name}"


def type_spec_reference(type_name: str) -> str:
    if type_name.startswith(":") or type_name.startswith("("):
        return type_name
    return f"{LOW_LEVEL_PACKAGE}::{type_name}"


def raw_output_slot_value(parameter: ParameterInfo, slot_name: str) -> str:
    type_name = parameter.pointee_cffi_spec or parameter.base_lisp_name
    return f"(cffi:mem-ref {slot_name} '{type_spec_reference(type_name)})"


def emit_result_lines(function: FunctionInfo, call_form: str) -> list[str]:
    outputs = output_parameters(function)
    if not outputs:
        return [call_form]
    if len(outputs) == 1:
        return [value_expression(outputs[0], call_form, function.public_lisp_name)]

    binding_names = [f"value-{index}" for index in range(len(outputs))]
    lines = [
        f"(multiple-value-bind ({' '.join(binding_names)})",
        f"    {call_form}",
        "  (cl:values",
    ]
    for index, parameter in enumerate(outputs):
        suffix = "))" if index == len(outputs) - 1 else ""
        lines.append(
            f"    {value_expression(parameter, binding_names[index], function.public_lisp_name)}{suffix}"
        )
    return lines


def emit_manual_call_lines(
    function: FunctionInfo, argument_map: dict[str, str]
) -> list[str]:
    outputs = output_parameters(function)
    slot_names = {parameter.lisp_name: f"{parameter.lisp_name}-slot" for parameter in outputs}
    lines: list[str] = []

    def recurse(index: int, current_indent: str) -> None:
        if index == len(outputs):
            for parameter in outputs:
                if parameter_mode(function, parameter) != "in-out":
                    continue
                lines.append(
                    f"{current_indent}(setf "
                    f"(cffi:mem-ref {slot_names[parameter.lisp_name]} "
                    f"'{type_spec_reference(parameter.pointee_cffi_spec)}) "
                    f"{argument_map[parameter.lisp_name]})"
                )

            call_arguments = []
            for parameter in function.parameters:
                mode = parameter_mode(function, parameter)
                if mode == "in":
                    call_arguments.append(argument_map[parameter.lisp_name])
                else:
                    call_arguments.append(slot_names[parameter.lisp_name])

            call_form = (
                f"({LOW_LEVEL_PACKAGE}:{function.public_lisp_name}"
                + "".join(f" {argument}" for argument in call_arguments)
                + ")"
            )
            if function.return_spec == "daq-err-code":
                lines.append(f"{current_indent}{call_form}")
                if not outputs:
                    lines.append(f"{current_indent}nil")
                elif len(outputs) == 1:
                    lines.append(
                        f"{current_indent}"
                        f"{value_expression(outputs[0], raw_output_slot_value(outputs[0], slot_names[outputs[0].lisp_name]), function.public_lisp_name)}"
                    )
                else:
                    lines.append(f"{current_indent}(cl:values")
                    for output_index, parameter in enumerate(outputs):
                        suffix = ")" if output_index == len(outputs) - 1 else ""
                        lines.append(
                            f"{current_indent}  "
                            f"{value_expression(parameter, raw_output_slot_value(parameter, slot_names[parameter.lisp_name]), function.public_lisp_name)}"
                            f"{suffix}"
                        )
                return

            if function.return_spec == ":void":
                lines.append(f"{current_indent}{call_form}")
                lines.append(f"{current_indent}nil")
                return

            lines.append(f"{current_indent}(let ((result {call_form}))")
            if not outputs:
                lines.append(f"{current_indent}  result)")
            else:
                lines.append(f"{current_indent}  (cl:values result")
                for output_index, parameter in enumerate(outputs):
                    suffix = "))" if output_index == len(outputs) - 1 else ""
                    lines.append(
                        f"{current_indent}    "
                        f"{value_expression(parameter, raw_output_slot_value(parameter, slot_names[parameter.lisp_name]), function.public_lisp_name)}"
                        f"{suffix}"
                    )
            return

        parameter = outputs[index]
        slot_name = slot_names[parameter.lisp_name]
        lines.append(
            f"{current_indent}(cffi:with-foreign-object "
            f"({slot_name} '{type_spec_reference(parameter.pointee_cffi_spec)})"
        )
        recurse(index + 1, current_indent + "  ")
        lines.append(f"{current_indent})")

    recurse(0, "")
    return lines


def emit_call_lines(spec: MethodSpec, parameter_names: tuple[str, ...]) -> list[str]:
    parameters = method_parameters(spec.function)
    argument_map: dict[str, str] = {}
    if uses_instance_receiver(spec.function):
        argument_map["self"] = "(%require-live-pointer object)"
    for parameter, argument in zip(parameters, parameter_names):
        argument_map[parameter.lisp_name] = argument

    if can_auto_wrap(spec.function):
        call_arguments = [argument_map[parameter.lisp_name] for parameter in call_parameters(spec.function)]
        call_form = (
            f"({LOW_LEVEL_PACKAGE}:{spec.function.public_lisp_name}"
            + "".join(f" {argument}" for argument in call_arguments)
            + ")"
        )
        return emit_result_lines(spec.function, call_form)

    return emit_manual_call_lines(spec.function, argument_map)


def emit_plain_function(spec: MethodSpec) -> list[str]:
    parameters = method_parameters(spec.function)
    lambda_tail = lambda_list(parameters, spec.optional_defaults)
    body_lines = emit_coerced_call(
        parameters,
        emit_call_lines(
            spec,
            tuple(f"coerced-{parameter.lisp_name}" for parameter in parameters),
        ),
        indent="  ",
    )
    return [
        f"(defun {spec.name} ({lambda_tail})" if lambda_tail else f"(defun {spec.name} ()",
        *body_lines,
        ")",
        "",
    ]


def emit_reader(spec: MethodSpec) -> list[str]:
    if not uses_instance_receiver(spec.function):
        return emit_plain_function(spec)

    parameters = method_parameters(spec.function)
    lambda_tail = lambda_list(parameters, spec.optional_defaults)
    generic_tail = generic_lambda_list(parameters, spec.optional_defaults)
    method_tail = (
        f"((object {spec.specializer}){(' ' + lambda_tail) if lambda_tail else ''})"
    )
    lines = [
        f"(defgeneric {spec.name} (object{(' ' + generic_tail) if generic_tail else ''}))",
        f"(defmethod {spec.name} {method_tail}",
    ]
    body_lines = emit_coerced_call(
        parameters,
        emit_call_lines(
            spec,
            tuple(f"coerced-{parameter.lisp_name}" for parameter in parameters),
        ),
        indent="  ",
    )
    lines.extend(body_lines)
    lines.extend([")", ""])
    return lines


def emit_writer(spec: MethodSpec) -> list[str]:
    if not uses_instance_receiver(spec.function):
        return emit_plain_function(spec)

    parameters = method_parameters(spec.function)
    if not parameters:
        raise ValueError(f"{spec.function.public_lisp_name} has no writable value.")
    accessor_parameters = parameters[:-1]
    value_parameter = parameters[-1]
    method_tail = (
        f"(new-value (object {spec.specializer})"
        + "".join(f" {parameter.lisp_name}" for parameter in accessor_parameters)
        + ")"
    )
    lines = [
        f"(defgeneric (setf {spec.name}) ({setter_lambda_list(accessor_parameters, spec.optional_defaults)}))",
        f"(defmethod (setf {spec.name}) {method_tail}",
    ]
    coerced_parameters = accessor_parameters + (
        ParameterInfo(
            c_name=value_parameter.c_name,
            lisp_name="new-value",
            cffi_spec=value_parameter.cffi_spec,
            base_type=value_parameter.base_type,
            base_lisp_name=value_parameter.base_lisp_name,
            base_kind=value_parameter.base_kind,
            pointer_depth=value_parameter.pointer_depth,
            pointer_like=value_parameter.pointer_like,
            pointee_cffi_spec=value_parameter.pointee_cffi_spec,
            pointee_kind=value_parameter.pointee_kind,
        ),
    )
    body_lines = emit_coerced_call(
        coerced_parameters,
        emit_call_lines(
            spec,
            tuple(
                [f"coerced-{parameter.lisp_name}" for parameter in accessor_parameters]
                + ["coerced-new-value"]
            ),
        ),
        indent="  ",
    )
    lines.extend(body_lines)
    lines.extend(["  new-value)", ""])
    return lines


def emit_method(spec: MethodSpec) -> list[str]:
    if not uses_instance_receiver(spec.function):
        return emit_plain_function(spec)

    parameters = method_parameters(spec.function)
    lambda_tail = lambda_list(parameters, spec.optional_defaults)
    generic_tail = generic_lambda_list(parameters, spec.optional_defaults)
    method_tail = (
        f"((object {spec.specializer}){(' ' + lambda_tail) if lambda_tail else ''})"
    )
    lines = [
        f"(defgeneric {spec.name} (object{(' ' + generic_tail) if generic_tail else ''}))",
        f"(defmethod {spec.name} {method_tail}",
    ]
    body_lines = emit_coerced_call(
        parameters,
        emit_call_lines(
            spec,
            tuple(f"coerced-{parameter.lisp_name}" for parameter in parameters),
        ),
        indent="  ",
    )
    lines.extend(body_lines)
    lines.extend([")", ""])
    return lines


def emit_read_samples_helper() -> list[str]:
    return [
        "(defgeneric read-samples (reader count &optional timeout-ms poll-interval))",
        "(defmethod read-samples ((reader stream-reader) count",
        "                         &optional (timeout-ms 1000) (poll-interval 0.01))",
        '  (when (minusp count)',
        '    (error "COUNT must be non-negative."))',
        "  (if (zerop count)",
        "      nil",
        "      (let ((reader-pointer (%require-live-pointer reader)))",
        "        (cffi:with-foreign-object (samples :double count)",
        "          (loop with total = 0",
        "                while (< total count)",
        "                do (multiple-value-bind (read-count status)",
        "                       (opendaq:stream-reader/read",
        "                        reader-pointer",
        "                        (cffi:inc-pointer samples",
        "                                          (* total (cffi:foreign-type-size :double)))",
        "                        (- count total)",
        "                        timeout-ms)",
        "                     (unwind-protect",
        "                         (if (zerop read-count)",
        "                             (sleep poll-interval)",
        "                             (incf total read-count))",
        "                       (%release-pointer status)))",
        "                finally (return",
        "                          (loop for index below count",
        "                                collect (cffi:mem-aref samples :double index))))))))",
        "",
    ]


def method_signature_shape(function: FunctionInfo, override: FunctionOverride) -> tuple[int, int]:
    parameters = method_parameters(function)
    kind = classify_function(function)
    if kind == "writer":
        return writer_shape(parameters, override.optional_defaults)
    return generic_shape(parameters, override.optional_defaults)


def select_class_constructors(functions: list[FunctionInfo]) -> dict[str, FunctionInfo]:
    selected: dict[str, FunctionInfo] = {}
    for function in functions:
        if classify_function(function) != "constructor":
            continue
        receiver = receiver_name(function)
        override = CLASS_OVERRIDES.get(receiver)
        if override is not None and override.constructor_name == function.public_lisp_name:
            selected[receiver] = function
            continue
        preferred_name = f"{receiver}/create-{receiver}"
        current = selected.get(receiver)
        if current is None:
            selected[receiver] = function
            continue
        if (
            CLASS_OVERRIDES.get(receiver, ClassOverride()).constructor_name is None
            and
            current.public_lisp_name != preferred_name
            and function.public_lisp_name == preferred_name
        ):
            selected[receiver] = function
    return selected


def select_method_names(functions: list[FunctionInfo]) -> dict[str, str]:
    groups: dict[tuple[str, str], list[FunctionInfo]] = {}
    for function in functions:
        kind = classify_function(function)
        if kind == "constructor":
            continue
        groups.setdefault((kind, exposed_name(function, kind)), []).append(function)

    names: dict[str, str] = {}
    for (kind, base_name), grouped in groups.items():
        static_functions = [
            function for function in grouped if not uses_instance_receiver(function)
        ]
        instance_functions = [
            function for function in grouped if uses_instance_receiver(function)
        ]

        for function in static_functions:
            names[function.public_lisp_name] = qualified_name(function, kind)

        shapes = {
            method_signature_shape(
                function, FUNCTION_OVERRIDES.get(function.public_lisp_name, FunctionOverride())
            )
            for function in instance_functions
        }
        # Qualify when multiple shapes share the same short name
        # (different specializers, different arg counts), or when reserved.
        qualify_instances = (
            len(shapes) > 1 or base_name in RESERVED_METHOD_NAMES
        )
        for function in instance_functions:
            names[function.public_lisp_name] = (
                qualified_name(function, kind) if qualify_instances else base_name
            )

    return names


def build_specs(functions: list[FunctionInfo]) -> tuple[list[ClassSpec], list[MethodSpec]]:
    method_names = select_method_names(functions)
    class_constructors = select_class_constructors(functions)

    classes: dict[str, ClassSpec] = {}
    methods: list[MethodSpec] = []

    constructors = {
        function.public_lisp_name: function
        for function in functions
        if classify_function(function) == "constructor"
    }

    for function in functions:
        kind = classify_function(function)
        receiver = receiver_name(function)

        if kind == "constructor":
            if class_constructors.get(receiver) != function:
                methods.append(
                    MethodSpec(
                        function=function,
                        kind="method",
                        name=qualified_name(function, "method"),
                        specializer=receiver,
                    )
                )
                continue
            class_override = CLASS_OVERRIDES.get(receiver, ClassOverride())
            classes[receiver] = ClassSpec(
                name=receiver,
                constructor=function,
                constructor_defaults=class_override.constructor_defaults,
            )
            continue

        for result_class in result_class_names(function):
            class_override = CLASS_OVERRIDES.get(result_class, ClassOverride())
            classes.setdefault(
                result_class,
                ClassSpec(
                    name=result_class,
                    constructor=constructors.get(f"{result_class}/create-{result_class}"),
                    constructor_defaults=class_override.constructor_defaults,
                ),
            )

        override = FUNCTION_OVERRIDES.get(function.public_lisp_name, FunctionOverride())
        methods.append(
            MethodSpec(
                function=function,
                kind=kind,
                name=method_names[function.public_lisp_name],
                specializer=override.specializer or receiver,
                optional_defaults=override.optional_defaults,
            )
        )

    for spec in methods:
        if spec.specializer == "managed-object":
            continue
        if spec.specializer not in classes:
            class_override = CLASS_OVERRIDES.get(spec.specializer, ClassOverride())
            classes[spec.specializer] = ClassSpec(
                name=spec.specializer,
                constructor=constructors.get(f"{spec.specializer}/create-{spec.specializer}"),
                constructor_defaults=class_override.constructor_defaults,
            )

    if "base-object" not in classes:
        classes["base-object"] = ClassSpec(name="base-object")

    ordered_classes = sorted(classes.values(), key=lambda spec: spec.name)
    return ordered_classes, methods


def export_symbols(classes: list[ClassSpec], methods: list[MethodSpec]) -> list[str]:
    exports = {"as-list-of", "release", "raw-pointer", "read-samples"}
    for spec in classes:
        exports.add(spec.name)
        exports.add(f"wrap-{spec.name}")
    for spec in methods:
        exports.add(spec.name)
    return sorted(exports)


def render_output(include_dir: Path) -> str:
    headers = collect_headers(include_dir)
    types = scan_types(headers)
    functions, _ = scan_functions(headers, types)
    classes, methods = build_specs(functions)
    exports = export_symbols(classes, methods)

    lines = [
        ";;; This file is autogenerated by tools/generate_high_level_bindings.py.",
        ";;; Do not edit it manually.",
        "",
        "(in-package #:opendaq.high-level)",
        "",
        "(eval-when (:compile-toplevel :load-toplevel :execute)",
        "  (shadow '(",
    ]

    for symbol in exports:
        lines.append(f"            {symbol}")
    lines.extend(["            ))", "  )", "", ""])

    for spec in classes:
        lines.extend(emit_class_definition(spec))
        lines.extend(constructor_lambda_lines(spec))
        lines.extend(emit_wrapper_constructor(spec))

    # Emit as-list-of helper: converts an openDAQ object-list into a proper
    # Lisp list, casting each element to a given wrapper type so that
    # type-specific generics work without manual casting.
    lines.extend([
        "",
        "(defun as-list-of (object-list target-type)",
        '  "Convert an openDAQ object-list into a proper Lisp list, casting each element',
        "to TARGET-TYPE (e.g. 'DEVICE-INFO) so that type-specific generics work.",
        "",
        "  Example: (as-list-of (wrap-object-list pointer) 'device-info)",
        "            => (#<DEVICE-INFO ...> #<DEVICE-INFO ...>)\"",
        "  (loop for i below (count object-list)",
        "        collect (as (item-at object-list i) target-type)))",
        "",
    ])

    for spec in methods:
        if spec.kind == "reader":
            lines.extend(emit_reader(spec))
        elif spec.kind == "writer":
            lines.extend(emit_writer(spec))
        elif spec.kind == "method":
            lines.extend(emit_method(spec))

    # Emit bridge methods: when the same method name appears on multiple
    # sibling specializers (e.g. signals-recursive on device and function-block),
    # add a fallback on their lowest common ancestor that tries each sibling.
    bridge_names: dict[str, list[MethodSpec]] = {}
    for spec in methods:
        if spec.kind not in ("method", "reader", "writer"):
            continue
        bridge_names.setdefault(spec.name, []).append(spec)
    for name, specs in bridge_names.items():
        specializers = list(dict.fromkeys(s.specializer for s in specs))  # dedup order-preserving
        if len(specializers) <= 1:
            continue
        lca = lowest_common_ancestor(set(specializers))
        if lca in specializers:
            continue
        # Emit a bridge on the LCA that tries each sibling in order.
        bridge_lines = _emit_polymorphic_bridge(name, specs, lca)
        if bridge_lines:
            lines.extend(bridge_lines)

    # Deduplicate defgenerics so each generic is defined only once.
    seen_generics: set[str] = set()
    deduped: list[str] = []
    for line in lines:
        if line.startswith("(defgeneric "):
            sig = line.split(")")[0]  # "(defgeneric name (object"
            if sig in seen_generics:
                continue
            seen_generics.add(sig)
        deduped.append(line)
    lines = deduped

    lines.extend(emit_read_samples_helper())

    lines.append("(export '(")
    for symbol in exports:
        lines.append(f"         {symbol}")
    lines.extend(["         ))", ""])
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate the high-level Common Lisp bindings layer."
    )
    parser.add_argument(
        "--output",
        required=True,
        type=Path,
        help="Path to the generated high-level Lisp file.",
    )
    parser.add_argument(
        "--include-dir",
        type=Path,
        default=DEFAULT_INCLUDE_DIR,
        help="Path to the openDAQ C headers used to derive the high-level wrappers.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(render_output(args.include_dir), encoding="utf-8")


if __name__ == "__main__":
    main()
