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


# High-level class names that can't use their natural openDAQ-derived name because
# it collides with a COMMON-LISP symbol (every key here is a CL type specifier, so a
# CLOS class of that name would force shadowing cl:integer, cl:float, ... and hijack
# the type specifier package-wide).  We disambiguate with an "-object" suffix instead
# of shadowing.  Names that don't collide (e.g. complex-number from IComplexNumber)
# are not listed and keep their natural name.
CLASS_NAME_OVERRIDES = {
    "boolean": "boolean-object",
    # complex-number (from IComplexNumber) does not collide with any CL symbol, so it
    # needs no rename for correctness -- it is listed only to carry the "-object" suffix
    # for consistency with the other boxed primitives (integer-object, float-object, ...).
    "complex-number": "complex-number-object",
    # openDAQ names the boxed-float interface IFloatObject (so its functions are
    # daqFloatObject_*, which already derive the class FLOAT-OBJECT) while the value
    # type is daqFloat (which would derive FLOAT, a CL collision).  Map both onto
    # FLOAT-OBJECT so the class, the daqFloat type, and the unboxer (see
    # PRIMITIVE-TYPE-P) all agree, matching the INTEGER-OBJECT / NUMBER-OBJECT family.
    "float": "float-object",
    "float-object": "float-object",
    "function": "function-object",
    "integer": "integer-object",
    "list": "object-list",
    "number": "number-object",
    "ratio": "ratio-object",
    "string": "string-object",
    "type": "type-object",
}

CLASS_OVERRIDES: dict[str, dict] = {
    # instance is a builder-backed type like any other -- its :builder kwarg folds in
    # createInstanceFromBuilder (see build_specs / constructor_lambda_lines).  Its only
    # specialness is that the builder defaults to one carrying the bundled native-module
    # path, so (make-instance 'instance) with no arguments yields a ready-to-use instance.
    "instance": {
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
            ("mode", ":scaled"),
            ("timeout-type", ":all"),
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

# Classes that intentionally get NO generated make-instance constructor.  openDAQ
# gives a property no plain createProperty(): it is built only through a typed factory
# (create-int-property, ...).  With no canonical constructor the generator used to
# silently pick the first create-* it saw (bool); suppress that.  The bare class stays
# wrappable from a pointer, and each typed create-* factory becomes a make-instance
# proxy subclass (property/int, property/bool, ...) like any other non-primary
# constructor.  (property-builder is NOT here: it has a real createPropertyBuilder(name).)
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

# Functions intentionally dropped because they are exact duplicates of another
# generated entry.  openDAQ exposes both daqFloatObject_createFloat and
# daqFloatObject_createFloatObject with identical (obj, value) signatures.  Since the
# class is FLOAT-OBJECT, createFloatObject is the natural make-instance primary (it is
# the {receiver}/create-{receiver} form select_class_constructors prefers), so suppress
# the createFloat duplicate -- otherwise it would surface as a redundant FLOAT-OBJECT/FLOAT
# proxy subclass.
SUPPRESSED_FUNCTIONS = {
    "float-object/create-float",
    # createBoolean(value) duplicates createBoolObject(value) (the boolean-object
    # make-instance primary, also what the boxing layer uses); drop the dup so it
    # does not surface as a redundant boolean-object/boolean proxy.
    "boolean/create-boolean",
    # createComponentDeserializeContext returns two values (the context plus an
    # out intf-id GUID), so it does not fit the single-object make-instance model.
    # It is an internal deserialization primitive, unused here; drop it (the class
    # is still wrappable and keeps its clone / interface-id methods).
    "component-deserialize-context/create-component-deserialize-context",
    # These take a daqIntfID GUID by value.  The low-level layer now binds them
    # (passed per-ABI; see generate_low_level_bindings), but they are plumbing:
    # the GUID query is exposed idiomatically as is-p /
    # component-type, and the untyped list/dict/folder constructors cover the
    # rest, so they need no high-level wrapper.
    "base-object/query-interface",
    "base-object/borrow-interface",
    "list/create-list-with-element-type",
    "dict/create-dict-with-expected-types",
    "folder-config/create-folder-with-item-type",
    "search-filter/create-interface-id-search-filter",
}

# Curated make-instance proxy names (BASE/SUFFIX) for factory constructors whose
# C name does not embed the type they build, so proxy_class_name cannot derive a
# clean suffix automatically (e.g. createIoFolder builds a folder-config).
PROXY_NAME_OVERRIDES: dict[str, str] = {
    # These build a component-type-builder; the shared "-type-builder" tail is not
    # a contiguous run with the receiver, so it survives auto-derivation as a
    # redundant suffix (component-type-builder/device-type-builder).  Trim it.
    "component-type-builder/create-device-type-builder": "component-type-builder/device",
    "component-type-builder/create-function-block-type-builder": "component-type-builder/function-block",
    "component-type-builder/create-server-type-builder": "component-type-builder/server",
    "component-type-builder/create-streaming-type-builder": "component-type-builder/streaming",
    # Shared leading "signal-" token, likewise not stripped by the contiguous-run rule.
    "signal-config/create-signal-with-descriptor": "signal-config/with-descriptor",
}

FUNCTION_OVERRIDES: dict[str, dict] = {
    # flag has no C default (openDAQ does not default it), but the binding chooses
    # to make it optional defaulting to t.  Args the C++ API itself defaults --
    # e.g. searchFilter = nullptr, config = nullptr -- no longer need an entry
    # here: optional_defaults_for derives them from the // [defaultValue(...)]
    # annotations carried on each parameter.
    "instance-builder/enable-standard-providers": {"optional_defaults": (("flag", "t"),)},
    # createFunctionBlock has two interface variants whose defaulted args differ in
    # order and count (module: id parent localId config=nullptr; module-manager-
    # utils: id parent config=nullptr localId=nullptr).  Honoring the defaults gives
    # them incongruent &optional shapes, which would split the shared
    # create-function-block generic into two qualified names.  Ignore the optionality
    # so both keep every argument required and stay unified under one generic.
    "module/create-function-block": {"ignore_default_values": True},
    "module-manager-utils/create-function-block": {"ignore_default_values": True},
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
# (clone, type, remove, read, ...).
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


# C has no default arguments, so RTGen records each one as a
# // [defaultValue(arg, literal)] annotation (see tools/parse_bindings.py),
# surfaced here as a parameter's "default_value".  These are the non-numeric
# literals; integer literals are translated by int(..., 0) below.
_C_DEFAULT_TO_LISP = {"nullptr": "nil", "true": "t", "false": "nil"}


def c_default_to_lisp(value: str) -> str:
    """Translate a C default-value literal into the Lisp form for an &optional."""
    if value in _C_DEFAULT_TO_LISP:
        return _C_DEFAULT_TO_LISP[value]
    if value.startswith('"') and value.endswith('"'):
        return value  # a C string literal is also a valid Lisp string
    try:
        return str(int(value, 0))  # decimal / hex / binary / octal integer literal
    except ValueError:
        raise ValueError(f"no Lisp mapping for C default value {value!r}")


def optional_defaults_for(function: dict, override: dict) -> tuple[tuple[str, str], ...]:
    """The (lisp_name, lisp_default) pairs for the function's trailing &optional args.

    Derived automatically from the C default-value annotations carried on each
    parameter, so an argument the C++ API defaults (e.g. searchFilter = nullptr)
    becomes optional without curation.  A manual FUNCTION_OVERRIDES["optional_defaults"]
    entry wins per parameter, and may also add an optional the C headers do not
    annotate (e.g. instance-builder/enable-standard-providers flag = t).  An
    override may set "ignore_default_values" to opt a function out of auto-derived
    optionals entirely (e.g. to keep a unified generic congruent)."""
    manual = dict(override.get("optional_defaults", ()))
    # A setf writer assigns a value to a place: its trailing parameter maps to
    # new-value and cannot be &optional (setter_lambda_list forbids it), so a C
    # default on it is not expressible -- don't auto-derive for writers.  An
    # "ignore_default_values" override opts a function out of auto-derivation too.
    auto = (
        classify_function(function) != "writer"
        and not override.get("ignore_default_values")
    )
    pairs: list[tuple[str, str]] = []
    seen: set[str] = set()
    for parameter in function["parameters"]:
        name = parameter["lisp_name"]
        if name in manual:
            pairs.append((name, manual[name]))
            seen.add(name)
        elif auto and parameter.get("default_value") is not None:
            pairs.append((name, c_default_to_lisp(parameter["default_value"])))
            seen.add(name)
    for name, default in manual.items():
        if name not in seen:
            pairs.append((name, default))
    return tuple(pairs)


BOXED_PRIMITIVE_TYPES = frozenset((
    "daq-base-object",
    "daq-integer",
    "daq-float-object",
    "daq-boolean",
    "daq-number",
    "daq-ratio",
    "daq-complex-number",
))


def coerce_category(parameter: dict) -> str | None:
    if parameter["base_lisp_name"] == "daq-string":
        return ":daq-string"
    if parameter["base_lisp_name"] in BOXED_PRIMITIVE_TYPES:
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
    return generic_shape(params, optional_defaults_for(function, override))


def qualified_name(function: dict, kind: str) -> str:
    return f"{receiver_name(function)}-{exposed_name(function, kind)}"


def factory_function_name(function: dict, kind: str) -> str:
    """Public name for a *static* (no-receiver) function.

    Constructor-shaped createXxx factories become make-instance proxy classes
    (see proxy_class_name), so they do not reach here.  A static createXxx that
    is *not* a clean constructor (e.g. an extra out-parameter makes it multi-
    valued) falls through to its bare stem CREATE-XXX -- mirroring openDAQ's free
    factory functions -- rather than the qualified RECEIVER-CREATE-XXX.  Other
    static functions keep the qualified name.
    """
    stem = exposed_name(function, kind)
    if stem.startswith("create-"):
        return stem
    return qualified_name(function, kind)


def _strip_token_run(body: str, tokens: str) -> str:
    """Remove the hyphen-delimited token run TOKENS from BODY wherever it appears
    contiguously, returning the remaining hyphen-joined tokens (cleaned up)."""
    bt = body.split("-")
    rt = tokens.split("-")
    for i in range(len(bt) - len(rt) + 1):
        if bt[i:i + len(rt)] == rt:
            del bt[i:i + len(rt)]
            break
    return "-".join(bt)


def proxy_class_name(function: dict) -> str:
    """make-instance proxy name BASE/SUFFIX for a non-primary factory constructor.

    openDAQ builds the variants of a polymorphic type, and a type's alternate
    constructors, through free factory functions (createIntProperty,
    createStreamReaderFromPort, ...).  Rather than expose those as detached
    create-* functions, each becomes a CLOS subclass of the type it builds, named
    BASE/SUFFIX, constructed via make-instance.  SUFFIX is the factory stem with
    the leading create- and the base type's own name removed (create-int-property
    -> property/int, create-stream-reader-from-port -> stream-reader/from-port).
    The handful whose names don't embed the base type are curated in
    PROXY_NAME_OVERRIDES.
    """
    pln = function["public_lisp_name"]
    if pln in PROXY_NAME_OVERRIDES:
        return PROXY_NAME_OVERRIDES[pln]
    receiver = receiver_name(function)
    stem = method_name(function)
    body = stem[len("create-"):] if stem.startswith("create-") else stem
    suffix = _strip_token_run(body, receiver)
    if not suffix:
        raise ValueError(
            f"empty proxy suffix for {pln!r}; add a PROXY_NAME_OVERRIDES entry")
    return f"{receiver}/{suffix}"


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
        required, _optional = _split_optional_params(params, optional_defaults_for(func, override))
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


def base_class_constructor(name: str, constructors: dict) -> dict | None:
    """The canonical create-<name> constructor that fills a bare class's
    make-instance, or None for a NO_DIRECT_CONSTRUCTOR class (which gets no
    generated constructor -- it is wrappable from a pointer and/or hand-written)."""
    if name in NO_DIRECT_CONSTRUCTOR:
        return None
    return constructors.get(f"{name}/create-{name}")


def build_specs(functions: list[dict]) -> tuple[list[dict], list[dict]]:
    method_names, unify_specs = select_method_names(functions)
    class_constructors = select_class_constructors(functions)

    classes: dict[str, dict] = {}
    methods: list[dict] = []

    constructors = {f["public_lisp_name"]: f for f in functions if classify_function(f) == "constructor"}

    for function in functions:
        if function["public_lisp_name"] in MANUAL_METHODS or function["public_lisp_name"] in SUPPRESSED_FUNCTIONS:
            continue
        kind = classify_function(function)
        receiver = receiver_name(function)

        if kind == "constructor":
            base = classes.setdefault(receiver, {
                "name": receiver,
                "constructor": base_class_constructor(receiver, constructors),
                "constructor_defaults": CLASS_OVERRIDES.get(receiver, {}).get("constructor_defaults", ()),
            })
            if class_constructors.get(receiver) == function:
                base["constructor"] = function
            elif function["public_lisp_name"].endswith("-from-builder"):
                # Fold the builder factory into the base class as a :builder kwarg
                # (see constructor_lambda_lines) rather than a separate /from-builder
                # subclass, so every builder-backed type constructs the same idiomatic
                # way: (make-instance 'foo :builder b).
                base["builder_constructor"] = function
            else:
                # Another non-primary factory (createIntProperty,
                # createStreamReaderFromPort, ...): a make-instance proxy subclass
                # BASE/SUFFIX of the type it builds.
                proxy = proxy_class_name(function)
                if proxy in classes:
                    raise ValueError(
                        f"proxy class name collision on {proxy!r} "
                        f"({function['public_lisp_name']})")
                classes[proxy] = {
                    "name": proxy, "parent": receiver, "constructor": function,
                    "constructor_defaults": (),
                }
            continue

        for result_class in result_class_names(function):
            co = CLASS_OVERRIDES.get(result_class, {})
            classes.setdefault(result_class, {
                "name": result_class,
                "constructor": base_class_constructor(result_class, constructors),
                "constructor_defaults": co.get("constructor_defaults", ()),
            })

        override = FUNCTION_OVERRIDES.get(function["public_lisp_name"], {})
        methods.append({
            "function": function, "kind": kind,
            "name": method_names[function["public_lisp_name"]],
            "specializer": override.get("specializer") or receiver,
            "optional_defaults": optional_defaults_for(function, override),
            "unify": unify_specs.get(function["public_lisp_name"]),
        })

    for spec in methods:
        if spec["specializer"] == "managed-object":
            continue
        if spec["specializer"] not in classes:
            co = CLASS_OVERRIDES.get(spec["specializer"], {})
            classes[spec["specializer"]] = {
                "name": spec["specializer"],
                "constructor": base_class_constructor(spec["specializer"], constructors),
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
    for spec in methods:
        exports.add(spec["name"])
    return sorted(exports)


def enum_type_aliases(types: dict) -> list[tuple[str, str]]:
    """(alias, low-level-name) pairs aliasing each clean low-level cenum under a
    prefix-free name in this package, so the enum *types* -- not just their keyword
    values -- are usable here, e.g. (cffi:foreign-enum-keyword 'operation-mode-type c).

    Only the cenums qualify: enums the low level had to emit as bare constants
    because of duplicate or unsupported values (e.g. daqSampleType) have no CFFI
    keyword mapping, so an alias would buy nothing and is skipped."""
    aliases = []
    for info in sorted(types.values(), key=lambda t: t["lisp_name"]):
        if info.get("kind") != "enum" or info["enum_has_duplicates"] or info["enum_has_unsupported_values"]:
            continue
        low = info["lisp_name"]
        aliases.append((low[len("daq-"):] if low.startswith("daq-") else low, low))
    return aliases


def _adopt_call(ctor: dict, params: list[dict], indent: str) -> list[str]:
    """The (%adopt-pointer object (low-level:CTOR coerced-args...)) form, with each
    PARAM boxed via WITH-DAQ-BOXED-VALUES, emitted at INDENT as one balanced expr."""
    return emit_coerced_call(
        params,
        [f"(%adopt-pointer object (opendaq.low-level:{ctor['public_lisp_name']}"
         + "".join(f" coerced-{p['lisp_name']}" for p in params) + "))"],
        indent=indent,
    )


def constructor_lambda_lines(spec: dict) -> list[str]:
    if spec["name"] in MANUAL_CONSTRUCTORS:
        return [""]
    constructor = spec.get("constructor")
    builder_constructor = spec.get("builder_constructor")
    if constructor is None and builder_constructor is None:
        return [""]
    if builder_constructor is None:
        return _plain_constructor_lines(spec, constructor)
    return _builder_constructor_lines(spec, constructor, builder_constructor)


def _plain_constructor_lines(spec: dict, constructor: dict) -> list[str]:
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
    construct_sentence = f"Constructs the instance via the openDAQ C function {constructor['c_name']}()."
    lines.extend(_string_literal_lines(_compose_doc_text(constructor, construct_sentence), "  "))
    lines.append(f"  (declare (ignore pointer{(' ' + ignore_clause) if ignore_clause else ''}))")

    call_body = _adopt_call(constructor, parameters, indent="  ")
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


def _builder_constructor_lines(spec: dict, constructor: dict | None, builder_constructor: dict) -> list[str]:
    """A constructor that folds in a <type>FromBuilder factory as a :builder kwarg.
    The body dispatches: an explicit :builder always wins; otherwise the regular
    constructor's required initargs build it directly; and when :builder carries a
    default (e.g. instance's bundled-module-path builder) or the regular constructor
    takes no args, a trailing fallback covers the no-args case."""
    defaults = default_map(spec.get("constructor_defaults", ()))
    regular_params = list(constructor_parameters(constructor)) if constructor is not None else []
    builder_params = list(constructor_parameters(builder_constructor))
    regular_required = [p for p in regular_params if p["lisp_name"] not in defaults]
    builder_has_default = any(p["lisp_name"] in defaults for p in builder_params)

    lines = [
        f"(defmethod initialize-instance :after ((object {spec['name']})",
        "                                       &key (pointer nil pointer-p)",
    ]
    for p in builder_params + regular_params:
        lines.append(f"                                            ({p['lisp_name']} {defaults.get(p['lisp_name'], 'nil')} {p['lisp_name']}-p)")
    lines.append("                                       &allow-other-keys)")
    if constructor is not None:
        construct_sentence = (
            f"Constructs the instance via the openDAQ C function {constructor['c_name']}(), "
            f"or from a builder via {builder_constructor['c_name']}() when :builder is supplied.")
        doc_source = constructor
    else:
        construct_sentence = f"Constructs the instance from a builder via {builder_constructor['c_name']}()."
        doc_source = builder_constructor
    lines.extend(_string_literal_lines(_compose_doc_text(doc_source, construct_sentence), "  "))
    lines.append("  (declare (ignore pointer))")

    builder_check = " ".join(f"{p['lisp_name']}-p" for p in builder_params)
    # (test, constructor, params) clauses; an explicit builder always wins.
    clauses = [(builder_check if len(builder_params) == 1 else f"(and {builder_check})",
                builder_constructor, builder_params)]
    if constructor is not None and regular_required:
        clauses.append(("(and " + " ".join(f"{p['lisp_name']}-p" for p in regular_required) + ")",
                        constructor, regular_params))
    if builder_has_default:
        clauses.append(("t", builder_constructor, builder_params))
    elif constructor is not None and not regular_required:
        clauses.append(("t", constructor, regular_params))

    lines.append("  (unless pointer-p")
    lines.append("    (cond")
    last = len(clauses) - 1
    for index, (test, ctor, params) in enumerate(clauses):
        lines.append(f"      ({test}")
        body = _adopt_call(ctor, params, indent="       ")
        # Last clause closes itself + the COND + the UNLESS + the DEFMETHOD.
        body[-1] = body[-1] + ("))))" if index == last else ")")
        lines.extend(body)
    lines.append("")
    return lines


def emit_class_definition(spec: dict) -> list[str]:
    parent = spec.get("parent") or class_parent(spec["name"])
    params: list[dict] = []
    if spec.get("constructor") is not None:
        params.extend(constructor_parameters(spec["constructor"]))
    if spec.get("builder_constructor") is not None:
        params.extend(constructor_parameters(spec["builder_constructor"]))
    seen: set[str] = set()
    slots = []
    for p in params:
        if p["lisp_name"] in seen:
            continue
        seen.add(p["lisp_name"])
        slots.append(f"   (%{p['lisp_name']}-initarg :initarg :{p['lisp_name']} :initform nil)")
    return [f"(defclass {spec['name']} ({parent})", "  (", *slots, "   ))", "", ""]


def emit_coerced_call(parameters: tuple[dict, ...], inner_lines: list[str], indent: str) -> list[str]:
    """Wrap INNER_LINES so each parameter is boxed for the call and released after.

    Emits a single WITH-DAQ-BOXED-VALUES form (the macro defined in runtime.lisp)
    binding one coerced-<name> per parameter; the macro centralises the per-argument
    coerce / unwind-protect / cleanup dance that used to be expanded inline at every
    call site.  A NIL category marks an argument that needs no boxing.  With no
    parameters there is nothing to box, so INNER_LINES are emitted directly.
    """
    if not parameters:
        return [f"{indent}{line}" if line else line for line in inner_lines]

    open_prefix = f"{indent}(with-daq-boxed-values ("
    align = " " * len(open_prefix)
    lines: list[str] = []
    for index, p in enumerate(parameters):
        category = coerce_category(p)
        binding = f"(coerced-{p['lisp_name']} {p['lisp_name']} {category if category is not None else 'nil'})"
        prefix = open_prefix if index == 0 else align
        closing = ")" if index == len(parameters) - 1 else ""
        lines.append(f"{prefix}{binding}{closing}")

    body = [f"{indent}  {line}" if line else line for line in inner_lines]
    body[-1] = body[-1] + ")"
    lines.extend(body)
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
            return f"(as-list-of (wrap {value_form} '{cn}) '{element_type})"
        if key_type and cn == "dict":
            key_type_lisp = _camel_to_kebab(key_type)
            val_type_lisp = _camel_to_kebab(value_type) if value_type else "t"
            return f"(as-hashtable-of (wrap {value_form} '{cn}) '{key_type_lisp} '{val_type_lisp})"
        return f"(wrap {value_form} '{cn})"
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


def generic_doc_key(spec: dict) -> str | None:
    """Dedup/aggregation key for the CLOS generic a method spec contributes to.

    Readers and (plain) methods share the generic named by SPEC["name"]; writers
    install a `(setf name)` generic, a distinct object from the same-named reader.
    Specs that do not dispatch on a receiver (free factory/static functions) emit a
    DEFUN rather than a generic, so they have no key.
    """
    if not uses_instance_receiver(spec["function"]):
        return None
    if spec["kind"] == "writer":
        return f"(setf {spec['name']})"
    return spec["name"]


def build_generic_docs(methods: list[dict]) -> dict[str, tuple[tuple[str, dict], ...]]:
    """Map each generic's key to the (specializer, function) of its every method.

    A single generic frequently fronts several C functions: the same operation is
    declared on multiple interfaces (so each class's method calls its own daqX_*),
    and the UNIFY_OPTIONAL generics deliberately fold C functions with incongruent
    arities behind one &optional lambda list.  Keeping every backing function lets
    the defgeneric docstring reuse each one's own openDAQ doc comment (and name the
    C function) instead of describing only the first one encountered.
    """
    docs: dict[str, list[tuple[str, dict]]] = {}
    for spec in methods:
        if spec["kind"] not in {"reader", "method", "writer"}:
            continue
        key = generic_doc_key(spec)
        if key is None:
            continue
        docs.setdefault(key, []).append((spec["specializer"], spec["function"]))
    return {key: tuple(entries) for key, entries in docs.items()}


def _escape_lisp_string(text: str) -> str:
    return text.replace("\\", "\\\\").replace('"', '\\"')


def clean_doxygen(raw: str) -> str:
    """Lightly tidy a raw openDAQ doxygen comment for use as a Lisp docstring.

    The text is reused verbatim except for dropping the leading `@brief ` marker
    (pure doxygen markup, not prose); every other tag/line is left untouched.
    """
    text = raw.strip()
    return re.sub(r"^@brief\s+", "", text).strip()


def _doc_brief(function: dict) -> str:
    cleaned = clean_doxygen(function.get("docstring", ""))
    return cleaned.split("\n", 1)[0].strip() if cleaned else ""


def _c_call_sentence(function: dict) -> str:
    return f"Calls the openDAQ C function {function['c_name']}()."


def _compose_doc_text(function: dict, sentence: str | None = None) -> str:
    """openDAQ doc comment for FUNCTION followed by the C call it makes.

    SENTENCE overrides the trailing "Calls ..." line (constructors phrase it as a
    construction).  Functions with no doc comment get just the C-call sentence.
    """
    cleaned = clean_doxygen(function.get("docstring", ""))
    if sentence is None:
        sentence = _c_call_sentence(function)
    return f"{cleaned}\n\n{sentence}" if cleaned else sentence


def _string_literal_lines(text: str, indent: str) -> list[str]:
    """Render TEXT as a (possibly multi-line) Lisp string literal.

    Continuation lines are emitted flush-left so the docstring's own content keeps
    its formatting rather than inheriting the source indentation.
    """
    parts = _escape_lisp_string(text).split("\n")
    if len(parts) == 1:
        return [f'{indent}"{parts[0]}"']
    return [f'{indent}"{parts[0]}', *parts[1:-1], f'{parts[-1]}"']


def _docstring_body_lines(function: dict, indent: str = "  ") -> list[str]:
    return _string_literal_lines(_compose_doc_text(function), indent)


def _generic_lines(header: str, entries: tuple[tuple[str, dict], ...]) -> list[str]:
    """Render a defgeneric (opened by HEADER) with a :documentation string drawn
    from the openDAQ doc comments of the C functions it dispatches to.

    A single backing function reuses its full doc comment (plus the C-call line).
    An "overloaded" generic -- several specializers, or a UNIFY_OPTIONAL group with
    incompatible arities -- lists each dispatching class beside the C function it
    calls and that function's brief, so every backing form is accounted for.
    """
    seen: set[tuple[str, str]] = set()
    unique: list[tuple[str, dict]] = []
    for specializer, function in entries:
        marker = (specializer, function["c_name"])
        if marker not in seen:
            seen.add(marker)
            unique.append((specializer, function))

    if len(unique) == 1:
        text = _compose_doc_text(unique[0][1])
    else:
        blocks = []
        for specializer, function in unique:
            block = f"{specializer} => {function['c_name']}()"
            brief = _doc_brief(function)
            if brief:
                block += f"\n    {brief}"
            blocks.append(block)
        text = "\n\n".join(blocks)

    lines = _string_literal_lines(text, "  (:documentation ")
    lines[-1] += "))"
    return [header, *lines]


def _emit_plain_function(spec: dict) -> tuple[str | None, list[str], list[str]]:
    function = spec["function"]
    params = method_parameters(function)
    tail = lambda_list(params, spec.get("optional_defaults", ()))
    body = emit_coerced_call(
        params,
        _emit_call_body(spec, tuple(f"coerced-{p['lisp_name']}" for p in params)),
        indent="  ",
    )
    header = f"(defun {spec['name']} ({tail})" if tail else f"(defun {spec['name']} ()"
    return None, [], [header, *_docstring_body_lines(function), *body, ")", ""]


def _emit_unified_method(spec: dict, generic_docs: dict[str, tuple[tuple[str, str], ...]]) -> tuple[str, list[str], list[str]]:
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

    generic_lines = _generic_lines(
        f"(defgeneric {spec['name']} (object {generic_tail})", generic_docs[spec["name"]])
    lines = [
        f"(defmethod {spec['name']} {method_tail}",
        *_docstring_body_lines(function),
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
    return spec["name"], generic_lines, lines


def _emit_instance_method(spec: dict, generic_docs: dict[str, tuple[tuple[str, str], ...]]) -> tuple[str | None, list[str], list[str]]:
    if not uses_instance_receiver(spec["function"]):
        return _emit_plain_function(spec)

    if spec.get("unify") is not None:
        return _emit_unified_method(spec, generic_docs)

    function = spec["function"]
    params = method_parameters(function)
    tail = lambda_list(params, spec.get("optional_defaults", ()))
    generic_tail = lambda_list(params, spec.get("optional_defaults", ()), with_defaults=False)
    method_tail = f"((object {spec['specializer']}){(' ' + tail) if tail else ''})"

    generic_lines = _generic_lines(
        f"(defgeneric {spec['name']} (object{(' ' + generic_tail) if generic_tail else ''})",
        generic_docs[spec["name"]])
    lines = [
        f"(defmethod {spec['name']} {method_tail}",
        *_docstring_body_lines(function),
    ]
    body = emit_coerced_call(
        params,
        _emit_call_body(spec, tuple(f"coerced-{p['lisp_name']}" for p in params)),
        indent="  ",
    )
    lines.extend(body)
    lines.extend([")", ""])
    return spec["name"], generic_lines, lines


def _emit_writer(spec: dict, generic_docs: dict[str, tuple[tuple[str, str], ...]]) -> tuple[str | None, list[str], list[str]]:
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
    generic_lines = _generic_lines(
        f"(defgeneric (setf {spec['name']}) ({setter_lambda_list(accessor_params, spec.get('optional_defaults', ()))})",
        generic_docs[f"(setf {spec['name']})"])
    lines = [
        f"(defmethod (setf {spec['name']}) {method_tail}",
        *_docstring_body_lines(function),
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
    return f"(setf {spec['name']})", generic_lines, lines




def render_output(include_dir: Path) -> str:
    records = parse_records(include_dir)
    types = build_types(records)
    functions, _ = build_raw_functions(records, types)
    classes, methods = build_specs(functions)
    aliases = enum_type_aliases(types)
    exports = sorted(set(export_symbols(classes, methods)) | {alias for alias, _ in aliases})

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

    generic_docs = build_generic_docs(methods)
    emitted_generics: set[str] = set()
    for spec in methods:
        kind = spec["kind"]
        if kind == "writer":
            generic_key, generic_lines, method_lines = _emit_writer(spec, generic_docs)
        elif kind in ("reader", "method"):
            generic_key, generic_lines, method_lines = _emit_instance_method(spec, generic_docs)
        else:
            continue
        # The defgeneric is shared by every method on the generic; emit it once (with
        # its aggregated docstring) the first time the generic is seen.
        if generic_key is not None and generic_key not in emitted_generics:
            emitted_generics.add(generic_key)
            lines.extend(generic_lines)
        lines.extend(method_lines)

    if aliases:
        lines.append(";;; Enum type aliases: prefix-free names for the low-level cenums, so the enum")
        lines.append(";;; types themselves (not just their keywords) are usable from this package,")
        lines.append(";;; e.g. (cffi:foreign-enum-keyword 'operation-mode-type code).")
        for alias, low in aliases:
            lines.append(f"(cffi:defctype {alias} opendaq.low-level::{low})")
        lines.append("")

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
