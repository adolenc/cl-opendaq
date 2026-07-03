#!/usr/bin/env python3
"""
parse_bindings.py - Walk openDAQ C binding headers and emit a JSONL stream
of parsed bindings (functions, interfaces, enums, typedefs, error codes).

Usage:
    python parse_bindings.py --opendaq-repo tmp/openDAQ/
    python parse_bindings.py --opendaq-repo tmp/openDAQ/ --kinds function interface

Each line of stdout is a JSON object with a "kind" discriminator.  Example:

  {"kind": "function",
   "name": "daqDevice_addDevices",
   "return_type": {"name": "daqErrCode"},
   "arguments": [
     {"name": "self",           "type": {"name": "daqDevice"}},
     {"name": "devices",        "type": {"name": "daqDict", "pointer_depth": 2, "key_type": "String", "value_type": "Device"}},
     {"name": "connectionArgs", "type": {"name": "daqDict", "pointer_depth": 1, "key_type": "String", "value_type": "PropertyObject"}}
   ],
   "docstring": "@brief Connects to multiple devices in parallel ...\\n...",
   "source_file": "bindings/c/include/copendaq/device/device.h"}

JSON schema (per kind):

  function:
    name           : str     — full C function name (e.g. "daqDevice_addDevices")
                               class / method split on the first '_'
    return_type    : TypeDesc
    arguments[]    : { name: str, type: TypeDesc, default_value: str? }
                               default_value present only for arguments that
                               carry a // [defaultValue(...)] annotation
    docstring      : str     - raw doxygen text with newlines preserved
    source_file    : str     - relative path from the repo root

  interface:
    name           : str     - e.g. "daqDevice"
    parent         : str     - parent interface from DECLARE_OPENDAQ_INTERFACE
    docstring      : str
    source_file    : str

  typedef:
    name           : str     - C typedef name
    category       : "opaque" | "struct" | "enum" | "callback" | "alias"
    pointer_depth  : int     - present only when > 0
    base_type      : str     - (alias only) underlying type name
    enum_entries[] : { name: str, value: int|null }
    struct_fields[]: { name: str, type: TypeDesc }

  error_code:
    name           : str     - symbolic name, normalized to the OPENDAQ_ spelling
                               (e.g. "OPENDAQ_ERR_NOTFOUND", "OPENDAQ_SUCCESS")
    code           : int     - full 32-bit status code (0x80000000 | type<<16 | code)
    source_file    : str     - relative path from the repo root

  TypeDesc  (inline object, never appears as a top-level record):
    name           : str     - base type (e.g. "daqDict", "uint32_t", "void")
    pointer_depth  : int?    - (>0 only) number of '*' levels (e.g. daqDict** has pointer_depth=2)
    key_type       : str?    - (Dict only) key type name
    value_type     : str?    - (List/Dict only) element/value type name
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, TypeVar

T = TypeVar("T")


# ---------------------------------------------------------------------------
# Patterns (compiled once)
# ---------------------------------------------------------------------------

# Single-line comment that wraps DECLARE_OPENDAQ_INTERFACE
IFACE_COMMENT_RE = re.compile(
    r"^\s*//\s*DECLARE_OPENDAQ_INTERFACE\s*\(\s*(\w+)\s*,\s*(\w+)\s*\)\s*$",
    re.M,
)

# Single-line [templateType(param, Key, Value)] or [elementType(param, Elem)]
_TEMPLATE_TYPE_RE = re.compile(
    r"^\s*//\s*\[(templateType|elementType)\s*\(\s*(\w+)\s*,\s*([\w,\s]+)\)\s*\]\s*$",
    re.M,
)

# Single-line [defaultValue(param, value)] — the source-language default for an
# argument (e.g. nullptr, 0, -1).  C has no default arguments, so RTGen preserves
# them as comment annotations alongside the templateType/elementType ones.
_DEFAULT_VALUE_RE = re.compile(
    r"^\s*//\s*\[defaultValue\s*\(\s*(\w+)\s*,\s*(.+?)\s*\)\s*\]\s*$",
    re.M,
)

# Doxygen /** ... @brief ... */ block (greedy across lines)
DOXY_BLOCK_RE = re.compile(r"/\*!.*?\*/", re.S)

# /* ... */ regular comment (non-doxygen)
REGULAR_BLOCK_COMMENT_RE = re.compile(r"/\*(?!!).*?\*/", re.S)
# // ... single-line comment (not matching our special annotations)
SL_COMMENT_RE = re.compile(r"//[^\n]*")

# Preprocessor directives
PREPROCESSOR_RE = re.compile(r"^\s*#.*$", re.M)

# Numeric #define for enum value resolution
DEFINE_RE = re.compile(
    r"^\s*#define\s+(?P<name>[A-Za-z_]\w*)\s+(?P<value>\(?[-+]?0[xX][0-9A-Fa-f]+|\(?[-+]?\d+\)?)\s*$",
    re.M,
)

# Error-code macros.  A status code is built by the DAQ_ERROR_CODE(type, code)
# macro as 0x80000000 | (type << 16) | code; the headers spell the macros with
# either a DAQ_ or OPENDAQ_ prefix interchangeably, and key the type by the
# suffix after ERRTYPE_ (e.g. GENERIC, OPENDAQ, COREOBJECTS).
ERRTYPE_DEFINE_RE = re.compile(r"#define\s+(?:OPENDAQ|DAQ)_ERRTYPE_(\w+)\s+0x([0-9A-Fa-f]+)u?")
ERROR_CODE_RE = re.compile(
    r"#define\s+(?:OPENDAQ|DAQ)_ERR_(\w+)\s+"
    r"(?:OPENDAQ|DAQ)_ERROR_CODE\(\s*(?:OPENDAQ|DAQ)_ERRTYPE_(\w+)\s*,\s*0x([0-9A-Fa-f]+)u?\s*\)"
)
SUCCESS_DEFINE_RE = re.compile(r"#define\s+(?:OPENDAQ|DAQ)_SUCCESS\s+0x([0-9A-Fa-f]+)u?")

# Opaque struct typedef: typedef struct daqFoo daqFoo;
OPAQUE_STRUCT_RE = re.compile(r"typedef\s+struct\s+(\w+)\s+(\w+)\s*;", re.S)

# Concrete struct typedef: typedef struct daqFoo { ... } daqFoo;
CONCRETE_STRUCT_RE = re.compile(
    r"typedef\s+struct\s+(\w+)\s*\{(?P<body>.*?)\}\s*(\w+)\s*;", re.S
)

# Enum typedef: typedef enum daqFoo { ... } daqFoo;
ENUM_RE = re.compile(
    r"typedef\s+enum\s+(\w+)\s*\{(?P<body>.*?)\}\s*(\w+)\s*;", re.S
)

# Function pointer typedef: typedef RetType (*daqCallback)(args);
FUNCTION_POINTER_RE = re.compile(
    r"typedef\s+(?P<ret>[^;()]+?)\(\s*\*\s*(\w+)\s*\)\s*\((?P<args>.*?)\)\s*;", re.S
)

# Simple typedef: typedef BaseType NewName;
SIMPLE_TYPEDEF_RE = re.compile(
    r"typedef\s+(?!struct\b)(?!enum\b)(.*?)\s+(\w+)\s*;"
)

# Function declaration: return_type EXPORTED daqName_method(args);
FUNCTION_RE = re.compile(
    r"([A-Za-z_][A-Za-z0-9_\s\*]*?)\s+EXPORTED\s+"
    r"(\w+)\s*\(([^;]*)\)\s*;",
    re.S,
)

# Argument split: type_and_name
ARG_SPLIT_RE = re.compile(r"^(?P<type>.+?)(?P<name>[A-Za-z_]\w*)$")

IGNORED_FILENAMES = {"copendaq_private.h"}


# ---------------------------------------------------------------------------
# Dataclasses for JSON output
# ---------------------------------------------------------------------------

@dataclass
class TypeDesc:
    """Describes a C type in the parsed output."""
    name: str          # base type name e.g. "daqDict", "uint32_t", "int"
    pointer_depth: int = 0  # number of * levels
    is_const: bool = False
    key_type: str | None = None     # for Dict: key type
    value_type: str | None = None   # for List: element type; for Dict: value type


@dataclass
class ArgumentDesc:
    """Describes one function argument."""
    name: str
    type: TypeDesc
    default_value: str | None = None    # source-language default, from a // [defaultValue(...)] annotation


@dataclass
class FunctionDesc:
    """Describes a parsed C function declaration."""
    kind: str = "function"
    name: str = ""                    # full C name e.g. daqDevice_getInfo
    return_type: TypeDesc | None = None
    arguments: list[ArgumentDesc] | None = None
    docstring: str = ""               # raw docstring (brief + params + details)
    source_file: str = ""             # relative path from repo root


@dataclass
class InterfaceDesc:
    """Describes a DECLARE_OPENDAQ_INTERFACE declaration."""
    kind: str = "interface"
    name: str = ""                    # e.g. daqDevice
    parent: str = ""                  # e.g. daqFolder
    docstring: str = ""
    source_file: str = ""


@dataclass
class ErrorCodeDesc:
    """Describes one openDAQ status code and its symbolic name."""
    kind: str = "error_code"
    name: str = ""                    # normalized to the OPENDAQ_ spelling, e.g. OPENDAQ_ERR_NOTFOUND
    code: int = 0                     # full 32-bit status code (0x80000000 | type<<16 | code)
    source_file: str = ""


@dataclass
class TypedefDesc:
    """Describes a typedef (opaque struct, enum, function pointer, alias)."""
    kind: str = "typedef"
    name: str = ""                    # e.g. daqDevice
    category: str = ""                # "opaque", "enum", "callback", "alias", "struct"
    base_type: str | None = None      # for aliases
    pointer_depth: int = 0            # for pointer aliases
    enum_entries: list[dict] | None = None  # [{name: "daqCtBool", value: 0}, ...]
    struct_fields: list[dict] | None = None
    docstring: str = ""
    source_file: str = ""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def normalize_type(type_spec: str) -> tuple[str, int, bool]:
    """Split a C type string into base name, pointer depth, const flag."""
    normalized = " ".join(type_spec.replace("*", " * ").split())
    tokens = normalized.split()
    is_const = "const" in tokens
    tokens = [t for t in tokens if t not in {"const", "volatile", "restrict"}]
    pointer_depth = tokens.count("*")
    base_tokens = [t for t in tokens if t != "*"]
    base = " ".join(base_tokens) if base_tokens else "void"
    return base, pointer_depth, is_const


def make_type_desc(type_spec: str) -> TypeDesc:
    """Create a TypeDesc from a raw C type specifier."""
    base, pd, is_const = normalize_type(type_spec)
    return TypeDesc(name=base, pointer_depth=pd, is_const=is_const)


def split_arg_decl(declaration: str) -> tuple[str, str]:
    """Split 'type name' into (type, name)."""
    declaration = " ".join(declaration.split())
    m = ARG_SPLIT_RE.match(declaration)
    if not m:
        raise ValueError(f"Cannot split argument declaration: {declaration}")
    return m.group("type").strip(), m.group("name")


def parse_enum_entries(body: str, defines: dict[str, int] | None = None) -> list[dict]:
    """Parse comma-separated enum entries, optionally with = value.
    Uses *defines* to resolve #define'd constant values."""
    if defines is None:
        defines = {}
    entries: list[dict] = []
    current_value: int | None = -1
    for raw_entry in body.split(","):
        entry = raw_entry.strip()
        if not entry:
            continue
        if "=" in entry:
            name, value_text = [part.strip() for part in entry.split("=", 1)]
            try:
                current_value = int(value_text, 0)
            except ValueError:
                # Try resolving via #define
                if value_text in defines:
                    current_value = defines[value_text]
                else:
                    current_value = None
        else:
            name = entry.strip()
            if current_value is not None:
                current_value += 1
        entries.append({"name": name, "value": current_value})
    return entries


def parse_struct_fields(body: str) -> list[dict]:
    """Parse semicolon-separated struct fields into name/type entries."""
    fields: list[dict] = []
    for raw_field in body.split(";"):
        field = raw_field.strip()
        if not field:
            continue
        try:
            type_part, name = split_arg_decl(field)
            td = make_type_desc(type_part)
            ftype: dict = {"name": td.name}
            if td.pointer_depth:
                ftype["pointer_depth"] = td.pointer_depth
            fields.append({"name": name, "type": ftype})
        except ValueError:
            continue
    return fields


def scan_numeric_defines(raw_text: str) -> dict[str, int]:
    """Collect #define'd integer constants for enum value resolution."""
    defines: dict[str, int] = {}
    for m in DEFINE_RE.finditer(raw_text):
        value_text = m.group("value").strip()
        if value_text.startswith("(") and value_text.endswith(")"):
            value_text = value_text[1:-1].strip()
        try:
            defines[m.group("name")] = int(value_text, 0)
        except ValueError:
            continue
    return defines


def extract_docstring_summary(doxy_text: str) -> str:
    """Extract a clean summary from a /*! ... */ doxygen block.

    Strips the comment delimiters and leading * on each line,
    then concatenates everything into one plain string.
    """
    # Remove the /*! and */
    inner = doxy_text[3:-2].strip()
    # Strip leading * on each line
    lines: list[str] = []
    for line in inner.split("\n"):
        stripped = line.strip()
        if stripped.startswith("*"):
            stripped = stripped[1:].strip()
        if stripped:
            lines.append(stripped)
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Main parser
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Association helpers (operate on line-indexed annotation maps)
# ---------------------------------------------------------------------------

def _blank_single_line_comments(text: str) -> str:
    """Replace // ... comments with spaces, preserving line positions and
    /*! ... */ doxygen blocks intact."""
    # Protect doxygen blocks first
    doxy_spans = [(m.start(), m.end()) for m in DOXY_BLOCK_RE.finditer(text)]
    chars = list(text)
    i = 0
    while i < len(chars) - 1:
        if chars[i] == "/" and chars[i + 1] == "/":
            # Don't blank inside doxygen blocks
            inside_doxy = any(start <= i < end for start, end in doxy_spans)
            if inside_doxy:
                i += 1
                continue
            # Blank from // to end of line
            while i < len(chars) and chars[i] != "\n":
                chars[i] = " "
                i += 1
        else:
            i += 1
    return "".join(chars)


def _blank_non_newlines(text: str) -> str:
    return re.sub(r"[^\n]", " ", text)

def _find_doc_for_decl(
    decl_offset: int,
    doxy_blocks: list[tuple[int, str]],
    code_only: str,
) -> str:
    """Return the docstring from the doxygen block immediately preceding
    *decl_offset*.

    A block counts only when nothing but whitespace separates its end from
    the declaration in *code_only* (a view of the source with every comment
    and preprocessor line blanked out).  This stops a declaration from
    inheriting the doc of an earlier sibling when another declaration sits
    between them — e.g. a factory function with no doc of its own must not
    pick up the previous method's doc."""
    best_end = -1
    best_raw = ""
    for end_off, raw in doxy_blocks:
        if best_end < end_off <= decl_offset:
            best_end = end_off
            best_raw = raw
    if not best_raw or code_only[best_end:decl_offset].strip():
        return ""
    return extract_docstring_summary(best_raw)


def _collect_annotations_before(
    func_ln: int, annotations: dict[int, list[T]]
) -> list[T]:
    """Return all annotations on lines before *func_ln*, flattened in line order.
    Clears consumed lines so they aren't reused by a later declaration."""
    result: list[T] = []
    consumed: list[int] = []
    for ln in sorted(annotations.keys()):
        if ln < func_ln:
            result.extend(annotations[ln])
            consumed.append(ln)
    for ln in consumed:
        del annotations[ln]
    return result


class HeaderParser:
    """Parses a single C header file and extracts bindings."""

    def __init__(self, source_file: str):
        self.source_file = source_file
        self.interfaces: list[InterfaceDesc] = []
        self.functions: list[FunctionDesc] = []
        self.typedefs: list[TypedefDesc] = []
        self.error_codes: list[ErrorCodeDesc] = []

    def parse(self, raw_text: str) -> None:
        """Parse raw header text and populate self.{interfaces, functions, typedefs}."""

        # --- Phase 1: scan raw text for doxygen blocks, DECLARE_OPENDAQ_INTERFACE,
        #     templateType annotations, and function declarations ---
        # We do this on raw text so positions are accurate for association.

        # Doxygen blocks: list of (end_offset, raw text), in source order.
        doxy_blocks: list[tuple[int, str]] = []
        for m in DOXY_BLOCK_RE.finditer(raw_text):
            doxy_blocks.append((m.end(), m.group(0)))

        # DECLARE_OPENDAQ_INTERFACE: list of (name, parent, decl_offset)
        ifaces: list[tuple[str, str, int]] = []
        for m in IFACE_COMMENT_RE.finditer(raw_text):
            ifaces.append((m.group(1), m.group(2), m.start()))

        # templateType / elementType annotations: line -> list
        template_annotations: dict[int, list[tuple[str, str | None, str | None]]] = {}
        for m in _TEMPLATE_TYPE_RE.finditer(raw_text):
            ln = raw_text[: m.start()].count("\n")
            kind = m.group(1)
            param_name = m.group(2)
            types_str = m.group(3)
            type_parts = [t.strip() for t in types_str.split(",")]
            if kind == "templateType" and len(type_parts) >= 2:
                template_annotations.setdefault(ln, []).append(
                    (param_name, type_parts[0], type_parts[-1])
                )
            elif kind == "elementType" or kind == "templateType":
                template_annotations.setdefault(ln, []).append(
                    (param_name, None, type_parts[0])
                )

        # defaultValue annotations: line -> list of (param_name, value)
        default_value_annotations: dict[int, list[tuple[str, str]]] = {}
        for m in _DEFAULT_VALUE_RE.finditer(raw_text):
            ln = raw_text[: m.start()].count("\n")
            default_value_annotations.setdefault(ln, []).append(
                (m.group(1), m.group(2).strip())
            )

        # Function declarations — match on raw text with single-line comments blanked out
        # (to avoid matching commented-out declarations)
        raw_no_sl = _blank_single_line_comments(
            PREPROCESSOR_RE.sub(
                lambda m: _blank_non_newlines(m.group(0)),
                REGULAR_BLOCK_COMMENT_RE.sub(lambda m: _blank_non_newlines(m.group(0)), raw_text),
            )
        )
        func_matches: list[tuple[int, int, str, str, str]] = []  # (offset, line, return_str, name, args_str)
        for m in FUNCTION_RE.finditer(raw_no_sl):
            ln = raw_no_sl[: m.start()].count("\n")
            func_matches.append((m.start(), ln, m.group(1).strip(), m.group(2), m.group(3).strip()))

        # Code-only view (all comments, doxygen and preprocessor blanked, length
        # preserved) used to verify a docstring sits immediately before a
        # declaration with no intervening code.
        fully_stripped = DOXY_BLOCK_RE.sub(lambda m: _blank_non_newlines(m.group(0)), raw_no_sl)

        # --- Phase 2: strip comments for structural parsing ---
        text_no_comments = REGULAR_BLOCK_COMMENT_RE.sub("", raw_text)
        text_no_comments = SL_COMMENT_RE.sub("", text_no_comments)
        text_no_comments = DOXY_BLOCK_RE.sub("", text_no_comments)
        text_no_comments = PREPROCESSOR_RE.sub("", text_no_comments)

        # Resolve #define constants for enum values
        defines = scan_numeric_defines(raw_text)

        # --- Phase 3: parse structural typedefs & collect category info ---
        type_categories: dict[str, str] = {}  # name -> "opaque" | "struct" | "enum" | "callback" | "alias"

        for m in OPAQUE_STRUCT_RE.finditer(text_no_comments):
            c_name = m.group(2)
            type_categories[c_name] = "opaque"
            self.typedefs.append(TypedefDesc(
                kind="typedef", name=c_name, category="opaque",
                pointer_depth=1, source_file=self.source_file,
            ))

        for m in CONCRETE_STRUCT_RE.finditer(text_no_comments):
            c_name = m.group(3)
            type_categories[c_name] = "struct"
            self.typedefs.append(TypedefDesc(
                kind="typedef", name=c_name, category="struct",
                struct_fields=parse_struct_fields(m.group("body")),
                source_file=self.source_file,
            ))

        for m in ENUM_RE.finditer(text_no_comments):
            c_name = m.group(3)
            type_categories[c_name] = "enum"
            self.typedefs.append(TypedefDesc(
                kind="typedef", name=c_name, category="enum",
                enum_entries=parse_enum_entries(m.group("body"), defines),
                source_file=self.source_file,
            ))

        for m in FUNCTION_POINTER_RE.finditer(text_no_comments):
            c_name = m.group(2)
            type_categories[c_name] = "callback"
            self.typedefs.append(TypedefDesc(
                kind="typedef", name=c_name, category="callback",
                pointer_depth=1, source_file=self.source_file,
            ))

        consumed_spans = (
            [m.span() for m in OPAQUE_STRUCT_RE.finditer(text_no_comments)]
            + [m.span() for m in CONCRETE_STRUCT_RE.finditer(text_no_comments)]
            + [m.span() for m in ENUM_RE.finditer(text_no_comments)]
            + [m.span() for m in FUNCTION_POINTER_RE.finditer(text_no_comments)]
        )
        mutable = list(text_no_comments)
        for start, end in consumed_spans:
            for i in range(start, end):
                mutable[i] = " "
        text_simple = "".join(mutable)
        for m in SIMPLE_TYPEDEF_RE.finditer(text_simple):
            base, pd, _ = normalize_type(m.group(1))
            alias_name = m.group(2)
            # Resolve category: if base is a known daq type, inherit; else it's a plain alias
            cat = type_categories.get(base, "alias")
            type_categories[alias_name] = cat
            self.typedefs.append(TypedefDesc(
                kind="typedef", name=alias_name, category=cat,
                base_type=base, pointer_depth=pd, source_file=self.source_file,
            ))

        # --- Phase 4: interfaces (associate immediately preceding doxygen block) ---
        for name, parent, off in ifaces:
            doc = _find_doc_for_decl(off, doxy_blocks, fully_stripped)
            self.interfaces.append(InterfaceDesc(
                name=name, parent=parent, docstring=doc,
                source_file=self.source_file,
            ))

        # --- Phase 5: functions with accurate docstring / templateType association ---
        for func_off, func_ln, return_type_str, func_name, args_str in func_matches:
            return_td = make_type_desc(return_type_str)

            # Parse arguments
            arguments: list[ArgumentDesc] = []
            if args_str and args_str != "void":
                for idx, raw_arg in enumerate(args_str.split(","), start=1):
                    raw_arg = raw_arg.strip()
                    try:
                        type_part, arg_name = split_arg_decl(raw_arg)
                    except ValueError:
                        arg_name = f"arg{idx}"
                        type_part = raw_arg
                    arg_td = make_type_desc(type_part)
                    arguments.append(ArgumentDesc(name=arg_name, type=arg_td))

            # Find templateType annotations between previous function and this one
            func_tts = _collect_annotations_before(func_ln, template_annotations)
            for pname, kt, vt in func_tts:
                for arg in arguments:
                    if arg.name == pname:
                        arg.type.key_type = kt
                        arg.type.value_type = vt
                        break

            # Attach default values from [defaultValue(...)] annotations
            func_defaults = _collect_annotations_before(func_ln, default_value_annotations)
            for pname, value in func_defaults:
                for arg in arguments:
                    if arg.name == pname:
                        arg.default_value = value
                        break

            # Find docstring
            doc = _find_doc_for_decl(func_off, doxy_blocks, fully_stripped)

            self.functions.append(FunctionDesc(
                name=func_name,
                return_type=return_td,
                arguments=arguments,
                docstring=doc,
                source_file=self.source_file,
            ))

        # --- Phase 6: error-code macros (DAQ_ERROR_CODE arithmetic) ---
        # Every openDAQ error header defines the ERRTYPE families it references,
        # so resolving them within the file is sufficient.
        families = {name: int(value, 16) for name, value in ERRTYPE_DEFINE_RE.findall(raw_text)}
        for value in SUCCESS_DEFINE_RE.findall(raw_text):
            self.error_codes.append(ErrorCodeDesc(
                name="OPENDAQ_SUCCESS", code=int(value, 16), source_file=self.source_file,
            ))
        for name, family, code in ERROR_CODE_RE.findall(raw_text):
            if family in families:
                self.error_codes.append(ErrorCodeDesc(
                    name=f"OPENDAQ_ERR_{name}",
                    code=0x80000000 | (families[family] << 16) | int(code, 16),
                    source_file=self.source_file,
                ))


# ---------------------------------------------------------------------------
# JSONL emitter
# ---------------------------------------------------------------------------

class DataclassEncoder(json.JSONEncoder):
    """Handles dataclass serialisation, skipping None, is_const:false, pointer_depth:0."""
    def default(self, obj):
        if hasattr(obj, "__dataclass_fields__"):
            d = {}
            for field_name in obj.__dataclass_fields__:
                value = getattr(obj, field_name)
                if value is None:
                    continue
                if field_name == "is_const" and value is False:
                    continue
                if field_name == "pointer_depth" and value == 0:
                    continue
                d[field_name] = value
            return d
        return super().default(obj)


def emit_jsonl(records: Iterable[InterfaceDesc | FunctionDesc | TypedefDesc]) -> None:
    """Write one JSON object per line to stdout."""
    for rec in records:
        print(json.dumps(rec, cls=DataclassEncoder))


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def collect_headers(repo_root: Path) -> list[Path]:
    """Collect all C binding header files under bindings/c/include/."""
    include_dir = repo_root / "bindings" / "c" / "include"
    if not include_dir.is_dir():
        # Try alternate: the repo is the include dir itself
        # (user might pass the include directory directly)
        alt = repo_root / "include"
        if alt.is_dir():
            include_dir = alt
        else:
            raise ValueError(
                f"No bindings/c/include/ or include/ found under {repo_root}"
            )
    headers: list[Path] = []
    for path in sorted(include_dir.rglob("*.h")):
        if path.name in IGNORED_FILENAMES or "private" in path.parts:
            continue
        headers.append(path)
    return headers


def parse_repo(repo_root: Path) -> list[InterfaceDesc | FunctionDesc | TypedefDesc | ErrorCodeDesc]:
    """Parse all headers in the repo and return a flat list of binding records."""
    headers = collect_headers(repo_root)
    if not headers:
        print(f"Warning: No headers found under {repo_root}", file=sys.stderr)
        return []

    records: list[InterfaceDesc | FunctionDesc | TypedefDesc | ErrorCodeDesc] = []
    for header_path in headers:
        try:
            rel_path = str(header_path.relative_to(repo_root))
        except ValueError:
            rel_path = str(header_path)

        raw_text = header_path.read_text(encoding="utf-8", errors="replace")
        parser = HeaderParser(source_file=rel_path)
        parser.parse(raw_text)
        records.extend(parser.interfaces)
        records.extend(parser.typedefs)
        records.extend(parser.functions)
        records.extend(parser.error_codes)

    return records


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Parse openDAQ C binding headers and emit JSONL to stdout."
    )
    ap.add_argument(
        "--opendaq-repo",
        type=Path,
        required=True,
        help="Path to the root of the openDAQ repository "
        "(containing bindings/c/include/).",
    )
    ap.add_argument(
        "--kinds",
        nargs="+",
        choices=["function", "interface", "typedef", "error_code"],
        default=["function", "interface", "typedef", "error_code"],
        help="Which kinds of binding records to emit (default: all).",
    )
    args = ap.parse_args()

    records = parse_repo(args.opendaq_repo)
    kinds = set(args.kinds)
    filtered = [r for r in records if r.kind in kinds]
    emit_jsonl(filtered)


if __name__ == "__main__":
    main()
