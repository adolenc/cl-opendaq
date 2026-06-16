#!/usr/bin/env python3

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from generate_low_level_bindings import (
    build_functions as build_raw_functions,
    build_types,
    can_auto_wrap,
    parameter_mode,
    parse_records,
)


DEFAULT_INCLUDE_DIR = Path(__file__).resolve().parents[1] / "include"


CLASS_NAME_OVERRIDES = {
    "boolean": "daq-boolean",
    "function": "daq-function",
    "integer": "daq-integer",
    "list": "object-list",
    "number": "daq-number",
    "string": "daq-string-object",
    "type": "daq-type",
}

CLASS_OVERRIDES: dict[str, dict] = {
    "instance": {
        "constructor_name": "instance/create-instance-from-builder",
        "constructor_defaults": (
            (
                "builder",
                "(let ((builder (make-instance 'instance-builder))) "
                "(setf (module-path builder) (native-library-directory)) "
                "builder)",
            ),
        ),
    },
    "multi-reader": {
        "constructor_defaults": (
            ("value-read-type", "opendaq.low-level::+daq-sample-type-float-64+"),
            ("domain-read-type", "opendaq.low-level::+daq-sample-type-int-64+"),
            ("mode", ":daq-read-mode-scaled"),
            ("timeout-type", ":daq-read-timeout-type-all"),
        )
    },
    # stream-reader, tail-reader and block-reader are constructed by hand via their
    # builders so the reader's skip-events flag can default to true (the direct create
    # call has no such parameter).  See MANUAL_CONSTRUCTORS and high-level-post-bindings.lisp.
}

# Explicit method-name overrides for individual functions, keyed by public lisp
# name (same key style as FUNCTION_OVERRIDES).  Use when the default naming would
# produce a name that is misleading or collides with something hand-written.
METHOD_NAME_OVERRIDES = {
    # Default would be a bare READ-SAMPLES (it is the only getter with that stem),
    # too easily confused with reader READ; name it explicitly instead.
    "block-reader-status/get-read-samples": "get-read-samples",
}

# Classes whose constructor is hand-written in the high-level layer (built via the
# reader builder so skip-events can default to true).  See high-level-post-bindings.lisp.
MANUAL_CONSTRUCTORS = {
    "stream-reader",
    "tail-reader",
    "block-reader",
}

# Classes that intentionally get NO direct make-instance constructor.  openDAQ gives
# a property no plain createProperty(): it is built only through one of its typed
# factory functions (create-int-property, ...).  With no canonical constructor the
# generator used to silently pick the first create-* it saw (bool), so make-instance
# arbitrarily produced a bool property.  Suppress that; the class is still wrappable
# from a pointer and its create-* factories are emitted as free factory functions.
# (property-builder is NOT here: it has a real createPropertyBuilder(name).)
NO_DIRECT_CONSTRUCTOR = {
    "property",
}

# Functions intentionally not auto-generated because they are hand-written in the
# high-level layer (their void** out-parameter buffers carry a runtime-typed
# payload the generator cannot model).  See high-level-post-bindings.lisp.
MANUAL_METHODS = {
    "data-packet/get-data",
    "data-packet/get-raw-data",
}

FUNCTION_OVERRIDES: dict[str, dict] = {
    "instance-builder/enable-standard-providers": {"optional_defaults": (("flag", "t"),)},
    "device/add-device": {"optional_defaults": (("config", "nil"),)},
    "device/get-signals": {"optional_defaults": (("search-filter", "nil"),)},
    "device/get-signals-recursive": {"optional_defaults": (("search-filter", "nil"),)},
    "server/get-signals": {"optional_defaults": (("search-filter", "nil"),)},
    "function-block/get-signals": {"optional_defaults": (("search-filter", "nil"),)},
    "function-block/get-signals-recursive": {"optional_defaults": (("search-filter", "nil"),)},
    # Extra args of UNIFY_OPTIONAL members that openDAQ makes nullptr-defaulted
    # (strictness rule 3): the unified generic must NOT require them.  See the
    # UNIFY_OPTIONAL comment and docs/method-name-unification.md.
    "data-packet/get-last-value": {"optional_defaults": (("type-manager", "nil"),)},
    "function-block/get-input-ports": {"optional_defaults": (("search-filter", "nil"),)},
    "user-lock/lock": {"optional_defaults": (("user", "nil"),)},
    "user-lock/unlock": {"optional_defaults": (("user", "nil"),)},
}

# Curated set of instance-method base names that are unified into a single CLOS
# generic via &optional padding instead of being qualified with a receiver prefix.
# openDAQ gives the same conceptual operation different arities across interfaces
# (e.g. signal.getLastValue() vs dataPacket.getLastValue(typeManager)); those
# lambda lists are not congruent, so the generator's fallback is to prefix the
# whole group (data-packet-last-value, signal-last-value, ...).
#
# For these base names we instead emit one generic whose lambda list is the union
# of the group's trailing extra args, all &optional, and have every method validate
# its own contract at runtime via supplied-p checks (no silent argument-eating, no
# silent null-passing).  Only groups whose arg lists *nest* (each a positional
# prefix of the longest) may appear here; _unify_method_group asserts this.
#
# Excluded on purpose: signal/component/address (coincidental name reuse -- they
# nest but mean unrelated things) and the genuinely divergent Group-2 names
# (clone, type, remove, read, ...).  See docs/method-name-unification.md.
UNIFY_OPTIONAL = {
    "last-value",
    "offset",
    "on-property-value-read",
    "on-property-value-write",
    "properties",
    "property",
    "input-ports",
    "lock",
    "unlock",
    "read-bool",
    "read-float",
    "read-int",
    "read-string",
    "read-serialized-list",
    "read-serialized-object",
}


def canonical_class_name(name: str) -> str:
    return CLASS_NAME_OVERRIDES.get(name, name)


def class_name_for_type(type_name: str) -> str | None:
    if type_name.startswith("daq-"):
        return canonical_class_name(type_name[4:])
    return None


def receiver_name(function: dict) -> str:
    return canonical_class_name(function["public_lisp_name"].partition("/")[0])


def method_name(function: dict) -> str:
    return function["public_lisp_name"].partition("/")[2]


def call_parameters(function: dict) -> tuple[dict, ...]:
    return tuple(p for p in function["parameters"] if parameter_mode(function, p) != "out")


def output_parameters(function: dict) -> tuple[dict, ...]:
    return tuple(p for p in function["parameters"] if parameter_mode(function, p) != "in")


def constructor_parameters(function: dict) -> tuple[dict, ...]:
    return tuple(p for p in function["parameters"] if p["lisp_name"] != "obj" and parameter_mode(function, p) != "out")


def classify_function(function: dict) -> str:
    stem = method_name(function)
    if stem.startswith("create-"):
        outputs = output_parameters(function)
        if not uses_instance_receiver(function) and len(outputs) == 1 and outputs[0]["lisp_name"] == "obj":
            return "constructor"
        return "method"
    if stem.startswith("get-"):
        return "reader"
    if stem.startswith("set-"):
        return "writer" if method_parameters(function) else "method"
    return "method"


HIERARCHY_CACHE: dict[str, str] | None = None


def _scan_interface_hierarchy(cpp_root: Path) -> dict[str, str]:
    def to_lisp_name(camel: str) -> str:
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
    global HIERARCHY_CACHE
    if HIERARCHY_CACHE is None:
        if cpp_root is None:
            cpp_root = DEFAULT_INCLUDE_DIR.parent / "tmp" / "openDAQ" / "core"
        HIERARCHY_CACHE = _scan_interface_hierarchy(cpp_root)
    if class_name == "managed-object":
        return "standard-object"
    return HIERARCHY_CACHE.get(class_name, "managed-object")



def exposed_name(function: dict, kind: str) -> str:
    stem = method_name(function)
    return stem.partition("-")[2] if kind in {"reader", "writer"} else stem


def uses_instance_receiver(function: dict) -> bool:
    params = call_parameters(function)
    return bool(params) and params[0]["lisp_name"] == "self"


def method_parameters(function: dict) -> tuple[dict, ...]:
    params = call_parameters(function)
    return params[1:] if uses_instance_receiver(function) else params


def result_class_names(function: dict) -> tuple[str, ...]:
    classes: list[str] = []
    for parameter in output_parameters(function):
        if parameter["base_lisp_name"] == "daq-string" or not parameter.get("pointer_like"):
            continue
        cn = class_name_for_type(parameter["base_lisp_name"])
        if cn is not None:
            classes.append(cn)
    return tuple(classes)


def default_map(defaults: tuple[tuple[str, str], ...]) -> dict[str, str]:
    return dict(defaults)


def coerce_category(parameter: dict) -> str | None:
    if parameter["base_lisp_name"] == "daq-string":
        return ":daq-string"
    if parameter["base_lisp_name"] == "daq-base-object":
        return ":daq-base-object"
    if parameter["base_lisp_name"] == "daq-bool":
        return ":daq-bool"
    if parameter.get("pointer_like") and parameter["pointer_depth"] == 1:
        return ":managed-pointer"
    return None


def _split_optional_params(
    parameters: tuple[dict, ...], optional_defaults: tuple[tuple[str, str], ...]
) -> tuple[list[dict], list[dict]]:
    defaults = default_map(optional_defaults)
    required_count = len(parameters)
    for idx, p in enumerate(parameters):
        if p["lisp_name"] in defaults:
            required_count = idx
            break
    optional = list(parameters[required_count:])
    if optional and any(p["lisp_name"] not in defaults for p in optional):
        raise ValueError("Optional defaults must cover a trailing suffix of parameters.")
    return list(parameters[:required_count]), optional


def lambda_list(
    parameters: tuple[dict, ...], optional_defaults: tuple[tuple[str, str], ...], with_defaults: bool = True
) -> str:
    non_optional, optional = _split_optional_params(parameters, optional_defaults)
    parts = [p["lisp_name"] for p in non_optional]
    if optional:
        parts.append("&optional")
        defaults = default_map(optional_defaults)
        if with_defaults:
            parts.extend(f"({p['lisp_name']} {defaults[p['lisp_name']]})" for p in optional)
        else:
            parts.extend(p["lisp_name"] for p in optional)
    return " ".join(parts)


def setter_lambda_list(parameters: tuple[dict, ...], optional_defaults: tuple[tuple[str, str], ...]) -> str:
    if optional_defaults:
        raise ValueError("Setf writers with optional arguments are not supported.")
    return " ".join(["new-value", "object", *(p["lisp_name"] for p in parameters)])


def generic_shape(parameters: tuple[dict, ...], optional_defaults: tuple[tuple[str, str], ...]) -> tuple[int, int]:
    req, opt = _split_optional_params(parameters, optional_defaults)
    return len(req), len(opt)


def method_signature_shape(function: dict, override: dict) -> tuple[int, int]:
    params = method_parameters(function)
    kind = classify_function(function)
    if kind == "writer":
        if not params:
            raise ValueError("Writers require at least one value parameter.")
        return (2 + len(params) - 1, 0)
    return generic_shape(params, override.get("optional_defaults", ()))


def qualified_name(function: dict, kind: str) -> str:
    return f"{receiver_name(function)}-{exposed_name(function, kind)}"


def factory_function_name(function: dict, kind: str) -> str:
    """Public name for a *static* (no-receiver) function.

    openDAQ exposes object construction as free factory functions (C++
    IntProperty(), LinearDataRule(), ...; Python opendaq.IntProperty(), ...).  A
    static `createXxx` therefore reads better -- and mirrors openDAQ -- as its
    bare stem CREATE-XXX rather than the qualified RECEIVER-CREATE-XXX, since
    there is no per-variant interface/class to attach it to.  Non-create static
    functions keep the qualified name.  The create-* stems are globally unique,
    so dropping the receiver introduces no collisions.
    """
    stem = exposed_name(function, kind)
    if stem.startswith("create-"):
        return stem
    return qualified_name(function, kind)


def select_class_constructors(functions: list[dict]) -> dict[str, dict]:
    selected: dict[str, dict] = {}
    for function in functions:
        if classify_function(function) != "constructor":
            continue
        receiver = receiver_name(function)
        if receiver in NO_DIRECT_CONSTRUCTOR:
            continue
        override = CLASS_OVERRIDES.get(receiver)
        if override is not None and override.get("constructor_name") == function["public_lisp_name"]:
            selected[receiver] = function
            continue
        preferred_name = f"{receiver}/create-{receiver}"
        current = selected.get(receiver)
        if current is None:
            selected[receiver] = function
        elif (
            CLASS_OVERRIDES.get(receiver, {}).get("constructor_name") is None
            and current["public_lisp_name"] != preferred_name
            and function["public_lisp_name"] == preferred_name
        ):
            selected[receiver] = function
    return selected


def _unify_method_group(
    base_name: str, instance: list[dict], names: dict[str, str], unify: dict[str, dict]
) -> None:
    """Fold a UNIFY_OPTIONAL instance-method group into one &optional generic.

    All methods get the unqualified BASE-NAME.  The generic's extra args are the
    union of the group's trailing args (the longest method's, since they nest),
    all &optional.  Each method records, per union param, whether it is REAL and
    REQUIRED, REAL and OPTIONAL (nullptr-defaulted -- via optional_defaults), or
    PADDING (this method's C function does not take it); _emit_unified_method
    turns that into the per-method supplied-p validation.
    """
    longest = max((method_parameters(f) for f in instance), key=len)

    # Validation guard: every arg list must be a positional prefix of the longest,
    # so a bad curation entry fails loudly instead of emitting incongruent methods.
    for func in instance:
        params = method_parameters(func)
        for index, param in enumerate(params):
            if index >= len(longest) or param["lisp_name"] != longest[index]["lisp_name"]:
                raise ValueError(
                    f"UNIFY_OPTIONAL group {base_name!r} does not nest: "
                    f"{func['public_lisp_name']} arg {param['lisp_name']!r} is not a "
                    f"prefix of {[p['lisp_name'] for p in longest]}.")

    union_params = list(longest)
    for func in instance:
        pln = func["public_lisp_name"]
        names[pln] = METHOD_NAME_OVERRIDES.get(pln, base_name)

        params = method_parameters(func)
        override = FUNCTION_OVERRIDES.get(pln, {})
        required, _optional = _split_optional_params(params, override.get("optional_defaults", ()))
        classification = []
        for index in range(len(union_params)):
            if index < len(required):
                classification.append("required")
            elif index < len(params):
                classification.append("optional")
            else:
                classification.append("padding")
        unify[pln] = {"union_params": union_params, "classification": classification}


def select_method_names(functions: list[dict]) -> tuple[dict[str, str], dict[str, dict]]:
    groups: dict[tuple[str, str], list[dict]] = {}
    for function in functions:
        kind = classify_function(function)
        if kind == "constructor":
            continue
        groups.setdefault((kind, exposed_name(function, kind)), []).append(function)

    names: dict[str, str] = {}
    unify: dict[str, dict] = {}
    for (kind, base_name), grouped in groups.items():
        static = [f for f in grouped if not uses_instance_receiver(f)]
        instance = [f for f in grouped if uses_instance_receiver(f)]

        for func in static:
            pln = func["public_lisp_name"]
            names[pln] = METHOD_NAME_OVERRIDES.get(pln, factory_function_name(func, kind))

        if base_name in UNIFY_OPTIONAL and kind in {"reader", "method"} and len(instance) > 1:
            _unify_method_group(base_name, instance, names, unify)
            continue

        shapes = {
            method_signature_shape(f, FUNCTION_OVERRIDES.get(f["public_lisp_name"], {}))
            for f in instance
        }
        qualify = len(shapes) > 1
        for func in instance:
            pln = func["public_lisp_name"]
            names[pln] = METHOD_NAME_OVERRIDES.get(
                pln, qualified_name(func, kind) if qualify else base_name)

    return names, unify


def build_specs(functions: list[dict]) -> tuple[list[dict], list[dict]]:
    method_names, unify_specs = select_method_names(functions)
    class_constructors = select_class_constructors(functions)

    classes: dict[str, dict] = {}
    methods: list[dict] = []

    constructors = {f["public_lisp_name"]: f for f in functions if classify_function(f) == "constructor"}

    for function in functions:
        if function["public_lisp_name"] in MANUAL_METHODS:
            continue
        kind = classify_function(function)
        receiver = receiver_name(function)

        if kind == "constructor":
            if class_constructors.get(receiver) != function:
                methods.append({
                    "function": function, "kind": "method",
                    "name": factory_function_name(function, "method"),
                    "specializer": receiver, "optional_defaults": (),
                })
                continue
            co = CLASS_OVERRIDES.get(receiver, {})
            classes[receiver] = {
                "name": receiver, "constructor": function,
                "constructor_defaults": co.get("constructor_defaults", ()),
            }
            continue

        for result_class in result_class_names(function):
            co = CLASS_OVERRIDES.get(result_class, {})
            classes.setdefault(result_class, {
                "name": result_class,
                "constructor": constructors.get(f"{result_class}/create-{result_class}"),
                "constructor_defaults": co.get("constructor_defaults", ()),
            })

        override = FUNCTION_OVERRIDES.get(function["public_lisp_name"], {})
        methods.append({
            "function": function, "kind": kind,
            "name": method_names[function["public_lisp_name"]],
            "specializer": override.get("specializer") or receiver,
            "optional_defaults": override.get("optional_defaults", ()),
            "unify": unify_specs.get(function["public_lisp_name"]),
        })

    for spec in methods:
        if spec["specializer"] == "managed-object":
            continue
        if spec["specializer"] not in classes:
            co = CLASS_OVERRIDES.get(spec["specializer"], {})
            classes[spec["specializer"]] = {
                "name": spec["specializer"],
                "constructor": constructors.get(f"{spec['specializer']}/create-{spec['specializer']}"),
                "constructor_defaults": co.get("constructor_defaults", ()),
            }

    if "base-object" not in classes:
        classes["base-object"] = {"name": "base-object", "constructor": None, "constructor_defaults": ()}

    return sorted(classes.values(), key=lambda s: s["name"]), methods


def export_symbols(classes: list[dict], methods: list[dict]) -> list[str]:
    exports = {"as-hashtable-of", "as-list-of", "release", "raw-pointer", "read", "read-with-domain",
               "data", "raw-data"}
    for spec in classes:
        exports.add(spec["name"])
        exports.add(f"wrap-{spec['name']}")
    for spec in methods:
        exports.add(spec["name"])
    return sorted(exports)


def constructor_lambda_lines(spec: dict) -> list[str]:
    if spec["constructor"] is None or spec["name"] in MANUAL_CONSTRUCTORS:
        return [""]

    constructor = spec["constructor"]
    parameters = constructor_parameters(constructor)
    defaults = default_map(spec.get("constructor_defaults", ()))
    required = tuple(p for p in parameters if p["lisp_name"] not in defaults)
    ignored = tuple(p for p in parameters if p["lisp_name"] in defaults)

    lines = [
        f"(defmethod initialize-instance :after ((object {spec['name']})",
        "                                       &key (pointer nil pointer-p)",
    ]
    for p in parameters:
        lines.append(f"                                            ({p['lisp_name']} {defaults.get(p['lisp_name'], 'nil')} {p['lisp_name']}-p)")
    ignore_clause = " ".join(f"{p['lisp_name']}-p" for p in ignored)
    lines.append("                                       &allow-other-keys)")
    lines.append(f"  (declare (ignore pointer{(' ' + ignore_clause) if ignore_clause else ''}))")

    call_body = emit_coerced_call(
        parameters,
        [f"(%adopt-pointer object (opendaq.low-level:{constructor['public_lisp_name']}"
         + "".join(f" coerced-{p['lisp_name']}" for p in parameters) + "))"],
        indent="  ",
    )

    if required:
        checks = " ".join(f"{p['lisp_name']}-p" for p in required)
        lines.append(f"  (when (and (not pointer-p) {checks})")
        lines.extend(call_body)
        lines.append("    ))")
    else:
        lines.append("  (unless pointer-p")
        lines.extend(call_body)
        lines.append("    ))")
    lines.append("")
    return lines


def emit_class_definition(spec: dict) -> list[str]:
    parent = class_parent(spec["name"])
    slots = (
        [f"   (%{p['lisp_name']}-initarg :initarg :{p['lisp_name']} :initform nil)"
         for p in constructor_parameters(spec["constructor"])]
        if spec["constructor"] is not None
        else []
    )
    return [f"(defclass {spec['name']} ({parent})", "  (", *slots, "   ))", "", ""]


def emit_wrapper_constructor(spec: dict) -> list[str]:
    return [
        f"(defun wrap-{spec['name']} (pointer)",
        "  (unless (or (null pointer) (cffi:null-pointer-p pointer))",
        f"    (make-instance '{spec['name']} :pointer pointer)))",
        "",
    ]


def emit_coerced_call(parameters: tuple[dict, ...], inner_lines: list[str], indent: str) -> list[str]:
    lines: list[str] = []

    def recurse(idx: int, cur_indent: str) -> None:
        if idx == len(parameters):
            lines.extend([f"{cur_indent}{line}" if line else line for line in inner_lines])
            return
        p = parameters[idx]
        cat = coerce_category(p)
        if cat is None:
            lines.append(f"{cur_indent}(let ((coerced-{p['lisp_name']} {p['lisp_name']}))")
            recurse(idx + 1, cur_indent + "  ")
            lines.append(f"{cur_indent})")
        else:
            lines.append(f"{cur_indent}(multiple-value-bind (coerced-{p['lisp_name']} cleanup-{p['lisp_name']})")
            lines.append(f"{cur_indent}    (%coerce-argument {p['lisp_name']} {cat})")
            lines.append(f"{cur_indent}  (unwind-protect")
            recurse(idx + 1, cur_indent + "      ")
            lines.append(f"{cur_indent}    (%cleanup-coerced-argument cleanup-{p['lisp_name']})))")

    recurse(0, indent)
    return lines


def _camel_to_kebab(name: str) -> str:
    hyphenated = re.sub(r"([a-z])([A-Z])", r"\1-\2", name).lower()
    return CLASS_NAME_OVERRIDES.get(hyphenated, hyphenated)


def value_expression(parameter: dict, value_form: str) -> str:
    if parameter["base_lisp_name"] == "daq-string":
        return f"(%daq-string-to-lisp-and-release {value_form})"
    if parameter["base_lisp_name"] == "daq-bool":
        return f"(not (zerop {value_form}))"
    cn = class_name_for_type(parameter["base_lisp_name"])
    if parameter.get("pointer_like") and cn is not None:
        value_type = parameter.get("value_type")
        key_type = parameter.get("key_type")
        if value_type and cn == "object-list":
            element_type = _camel_to_kebab(value_type)
            return f"(as-list-of (wrap-{cn} {value_form}) '{element_type})"
        if key_type and cn == "dict":
            key_type_lisp = _camel_to_kebab(key_type)
            val_type_lisp = _camel_to_kebab(value_type) if value_type else "t"
            return f"(as-hashtable-of (wrap-{cn} {value_form}) '{key_type_lisp} '{val_type_lisp})"
        return f"(wrap-{cn} {value_form})"
    return value_form


def _type_spec_ref(type_name: str) -> str:
    return type_name if type_name.startswith(":") or type_name.startswith("(") else f"opendaq.low-level::{type_name}"


def _raw_output_slot_value(parameter: dict, slot_name: str) -> str:
    type_name = parameter["pointee_cffi_spec"] or parameter["base_lisp_name"]
    return f"(cffi:mem-ref {slot_name} '{_type_spec_ref(type_name)})"


def _emit_result(function: dict, call_form: str) -> list[str]:
    outputs = output_parameters(function)
    if not outputs:
        return [call_form]
    if len(outputs) == 1:
        return [value_expression(outputs[0], call_form)]

    binding_names = [f"value-{idx}" for idx in range(len(outputs))]
    lines = [f"(multiple-value-bind ({' '.join(binding_names)})", f"    {call_form}", "  (cl:values"]
    for idx, param in enumerate(outputs):
        suffix = "))" if idx == len(outputs) - 1 else ""
        lines.append(f"    {value_expression(param, binding_names[idx])}{suffix}")
    return lines


def _emit_manual_call(function: dict, argument_map: dict[str, str]) -> list[str]:
    outputs = output_parameters(function)
    slot_names = {p["lisp_name"]: f"{p['lisp_name']}-slot" for p in outputs}
    lines: list[str] = []

    def recurse(idx: int, cur_indent: str) -> None:
        if idx == len(outputs):
            for param in outputs:
                if parameter_mode(function, param) != "in-out":
                    continue
                lines.append(
                    f"{cur_indent}(setf "
                    f"(cffi:mem-ref {slot_names[param['lisp_name']]} "
                    f"'{_type_spec_ref(param['pointee_cffi_spec'])}) "
                    f"{argument_map[param['lisp_name']]})"
                )

            call_args = []
            for param in function["parameters"]:
                mode = parameter_mode(function, param)
                call_args.append(argument_map[param["lisp_name"]] if mode == "in" else slot_names[param["lisp_name"]])

            call_form = f"(opendaq.low-level:{function['public_lisp_name']}" + "".join(f" {a}" for a in call_args) + ")"

            ret = function["return_spec"]
            if ret == "daq-err-code":
                lines.append(f"{cur_indent}{call_form}")
                if not outputs:
                    lines.append(f"{cur_indent}nil")
                elif len(outputs) == 1:
                    p = outputs[0]
                    lines.append(f"{cur_indent}{value_expression(p, _raw_output_slot_value(p, slot_names[p['lisp_name']]))}")
                else:
                    lines.append(f"{cur_indent}(cl:values")
                    for oi, p in enumerate(outputs):
                        sfx = ")" if oi == len(outputs) - 1 else ""
                        lines.append(f"{cur_indent}  {value_expression(p, _raw_output_slot_value(p, slot_names[p['lisp_name']]))}{sfx}")
                return

            if ret == ":void":
                lines.append(f"{cur_indent}{call_form}")
                lines.append(f"{cur_indent}nil")
                return

            lines.append(f"{cur_indent}(let ((result {call_form}))")
            if not outputs:
                lines.append(f"{cur_indent}  result)")
            else:
                lines.append(f"{cur_indent}  (cl:values result")
                for oi, p in enumerate(outputs):
                    sfx = "))" if oi == len(outputs) - 1 else ""
                    lines.append(f"{cur_indent}    {value_expression(p, _raw_output_slot_value(p, slot_names[p['lisp_name']]))}{sfx}")
            return

        param = outputs[idx]
        slot_name = slot_names[param["lisp_name"]]
        lines.append(f"{cur_indent}(cffi:with-foreign-object ({slot_name} '{_type_spec_ref(param['pointee_cffi_spec'])})")
        recurse(idx + 1, cur_indent + "  ")
        lines.append(f"{cur_indent})")

    recurse(0, "")
    return lines


def _emit_call_body(spec: dict, parameter_names: tuple[str, ...]) -> list[str]:
    function = spec["function"]
    params = method_parameters(function)
    argument_map: dict[str, str] = {}
    if uses_instance_receiver(function):
        argument_map["self"] = "(%require-live-pointer object)"
    for param, arg in zip(params, parameter_names):
        argument_map[param["lisp_name"]] = arg

    if can_auto_wrap(function):
        call_args = [argument_map[p["lisp_name"]] for p in call_parameters(function)]
        call_form = f"(opendaq.low-level:{function['public_lisp_name']}" + "".join(f" {a}" for a in call_args) + ")"
        return _emit_result(function, call_form)

    return _emit_manual_call(function, argument_map)


def _emit_plain_function(spec: dict) -> list[str]:
    function = spec["function"]
    params = method_parameters(function)
    tail = lambda_list(params, spec.get("optional_defaults", ()))
    body = emit_coerced_call(
        params,
        _emit_call_body(spec, tuple(f"coerced-{p['lisp_name']}" for p in params)),
        indent="  ",
    )
    header = f"(defun {spec['name']} ({tail})" if tail else f"(defun {spec['name']} ()"
    return [header, *body, ")", ""]


def _emit_unified_method(spec: dict) -> list[str]:
    """Emit one member of a UNIFY_OPTIONAL generic (see _unify_method_group).

    The generic's lambda list is (object &optional <union args>); every method
    shares it for congruence and validates its own contract via supplied-p:
    PADDING args must be omitted, REQUIRED args must be supplied, OPTIONAL
    (nullptr-defaulted) args may be either.
    """
    function = spec["function"]
    params = method_parameters(function)
    unify = spec["unify"]
    union_names = [p["lisp_name"] for p in unify["union_params"]]
    classification = unify["classification"]

    # OPTIONAL (nullptr-defaulted) args carry no supplied-p check, so omit their
    # supplied-p variable to avoid an "unused variable" warning.  Supplied-p
    # variables do not affect generic congruence, so methods may differ here.
    generic_tail = "&optional " + " ".join(union_names)
    method_optionals = " ".join(
        f"({name} nil {name}-suppliedp)" if kind != "optional" else f"({name} nil)"
        for name, kind in zip(union_names, classification))
    method_tail = f"((object {spec['specializer']}) &optional {method_optionals})"

    lines = [
        f"(defgeneric {spec['name']} (object {generic_tail}))",
        f"(defmethod {spec['name']} {method_tail}",
    ]

    padding = [name for name, kind in zip(union_names, classification) if kind == "padding"]
    if padding:
        lines.append(f"  (declare (ignore {' '.join(padding)}))")

    name_upper = spec["name"].upper()
    for name, kind in zip(union_names, classification):
        if kind == "padding":
            lines.append(f"  (when {name}-suppliedp")
            lines.append(
                f"    (error \"{name_upper} is not applicable with a {name.upper()} "
                f"argument for ~S.\" '{spec['specializer']}))")
        elif kind == "required":
            lines.append(f"  (unless {name}-suppliedp")
            lines.append(
                f"    (error \"{name_upper} requires a {name.upper()} "
                f"argument for ~S.\" '{spec['specializer']}))")

    body = emit_coerced_call(
        params,
        _emit_call_body(spec, tuple(f"coerced-{p['lisp_name']}" for p in params)),
        indent="  ",
    )
    lines.extend(body)
    lines.extend([")", ""])
    return lines


def _emit_instance_method(spec: dict) -> list[str]:
    if not uses_instance_receiver(spec["function"]):
        return _emit_plain_function(spec)

    if spec.get("unify") is not None:
        return _emit_unified_method(spec)

    function = spec["function"]
    params = method_parameters(function)
    tail = lambda_list(params, spec.get("optional_defaults", ()))
    generic_tail = lambda_list(params, spec.get("optional_defaults", ()), with_defaults=False)
    method_tail = f"((object {spec['specializer']}){(' ' + tail) if tail else ''})"

    lines = [
        f"(defgeneric {spec['name']} (object{(' ' + generic_tail) if generic_tail else ''}))",
        f"(defmethod {spec['name']} {method_tail}",
    ]
    body = emit_coerced_call(
        params,
        _emit_call_body(spec, tuple(f"coerced-{p['lisp_name']}" for p in params)),
        indent="  ",
    )
    lines.extend(body)
    lines.extend([")", ""])
    return lines


def _emit_writer(spec: dict) -> list[str]:
    if not uses_instance_receiver(spec["function"]):
        return _emit_plain_function(spec)

    function = spec["function"]
    params = method_parameters(function)
    if not params:
        raise ValueError(f"{function['public_lisp_name']} has no writable value.")
    accessor_params = params[:-1]
    value_param = params[-1]

    method_tail = (
        f"(new-value (object {spec['specializer']})"
        + "".join(f" {p['lisp_name']}" for p in accessor_params) + ")"
    )
    lines = [
        f"(defgeneric (setf {spec['name']}) ({setter_lambda_list(accessor_params, spec.get('optional_defaults', ()))}))",
        f"(defmethod (setf {spec['name']}) {method_tail}",
    ]

    coerced_params = accessor_params + (
        {
            "c_name": value_param["c_name"],
            "lisp_name": "new-value",
            "cffi_spec": value_param["cffi_spec"],
            "base_type": value_param["base_type"],
            "base_lisp_name": value_param["base_lisp_name"],
            "base_kind": value_param["base_kind"],
            "pointer_depth": value_param["pointer_depth"],
            "pointer_like": value_param.get("pointer_like", False),
            "pointee_cffi_spec": value_param["pointee_cffi_spec"],
            "pointee_kind": value_param["pointee_kind"],
        },
    )
    arg_names = tuple([f"coerced-{p['lisp_name']}" for p in accessor_params] + ["coerced-new-value"])
    body = emit_coerced_call(coerced_params, _emit_call_body(spec, arg_names), indent="  ")
    lines.extend(body)
    lines.extend(["  new-value)", ""])
    return lines




def render_output(include_dir: Path) -> str:
    records = parse_records(include_dir)
    types = build_types(records)
    functions, _ = build_raw_functions(records, types)
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

    for spec in methods:
        kind = spec["kind"]
        if kind == "writer":
            lines.extend(_emit_writer(spec))
        elif kind in ("reader", "method"):
            lines.extend(_emit_instance_method(spec))

    seen_generics: set[str] = set()
    deduped: list[str] = []
    for line in lines:
        if line.startswith("(defgeneric "):
            sig = line.split(")")[0]
            if sig in seen_generics:
                continue
            seen_generics.add(sig)
        deduped.append(line)
    lines = deduped

    lines.append("(export '(")
    for symbol in exports:
        lines.append(f"         {symbol}")
    lines.extend(["         ))", ""])
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate the high-level Common Lisp bindings layer.")
    parser.add_argument("--output", required=True, type=Path, help="Path to the generated high-level Lisp file.")
    parser.add_argument(
        "--include-dir", type=Path, default=DEFAULT_INCLUDE_DIR,
        help="Path to the openDAQ C headers used to derive the high-level wrappers.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        generated = render_output(args.include_dir)
    except Exception as exc:  # noqa: BLE001
        print(f"error: {exc}", file=sys.stderr)
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(generated, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
