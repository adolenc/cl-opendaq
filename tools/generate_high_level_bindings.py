#!/usr/bin/env python3

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path

from generate_bindings import (
    FunctionInfo,
    ParameterInfo,
    can_auto_wrap,
    collect_headers,
    parameter_mode,
    scan_functions,
    scan_types,
)

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
    lines = [
        f"(defmethod initialize-instance :after ((object {spec.name})",
        "                                       &key (pointer nil pointer-p)",
    ]
    for parameter in parameters:
        default = defaults.get(parameter.lisp_name, "nil")
        lines.append(
            f"                                            ({parameter.lisp_name} {default} {parameter.lisp_name}-p)"
        )
    lines.extend(["                                       &allow-other-keys)"])

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


def value_expression(parameter: ParameterInfo, value_form: str) -> str:
    if parameter.base_lisp_name == "daq-string":
        return f"(%daq-string-to-lisp-and-release {value_form})"
    if parameter.base_lisp_name == "daq-bool":
        return f"(not (zerop {value_form}))"
    class_name = class_name_for_type(parameter.base_lisp_name)
    if parameter.pointer_like and class_name is not None:
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
        return [value_expression(outputs[0], call_form)]

    binding_names = [f"value-{index}" for index in range(len(outputs))]
    lines = [
        f"(multiple-value-bind ({' '.join(binding_names)})",
        f"    {call_form}",
        "  (cl:values",
    ]
    for index, parameter in enumerate(outputs):
        suffix = "))" if index == len(outputs) - 1 else ""
        lines.append(
            f"    {value_expression(parameter, binding_names[index])}{suffix}"
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
                        f"{value_expression(outputs[0], raw_output_slot_value(outputs[0], slot_names[outputs[0].lisp_name]))}"
                    )
                else:
                    lines.append(f"{current_indent}(cl:values")
                    for output_index, parameter in enumerate(outputs):
                        suffix = ")" if output_index == len(outputs) - 1 else ""
                        lines.append(
                            f"{current_indent}  "
                            f"{value_expression(parameter, raw_output_slot_value(parameter, slot_names[parameter.lisp_name]))}"
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
                        f"{value_expression(parameter, raw_output_slot_value(parameter, slot_names[parameter.lisp_name]))}"
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
    exports = {"release", "raw-pointer", "read-samples"}
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
