#!/usr/bin/env python3

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path

from generate_bindings import (
    FunctionInfo,
    ParameterInfo,
    collect_headers,
    parameter_mode,
    scan_functions,
    scan_types,
)

LOW_LEVEL_PACKAGE = "opendaq"
DEFAULT_INCLUDE_DIR = Path(__file__).resolve().parents[1] / "include"


@dataclass(frozen=True)
class ClassOverride:
    constructor_defaults: tuple[tuple[str, str], ...] = ()


@dataclass(frozen=True)
class FunctionOverride:
    specializer: str | None = None
    optional_defaults: tuple[tuple[str, str], ...] = ()
    receiver_coercion: str | None = None


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
    receiver_coercion: str | None = None


TARGET_FUNCTIONS = (
    "ratio/create-ratio",
    "ratio/get-numerator",
    "ratio/get-denominator",
    "ratio/simplify",
    "instance/create-instance-from-builder",
    "instance-builder/create-instance-builder",
    "instance-builder/get-module-path",
    "instance-builder/set-module-path",
    "instance-builder/enable-standard-providers",
    "instance-builder/build",
    "instance/get-root-device",
    "device/add-device",
    "device/get-signals",
    "device/get-signals-recursive",
    "function-block/get-signals",
    "function-block/get-signals-recursive",
    "component/find-component",
    "list/get-item-at",
    "property-object/get-property-value",
    "property-object/set-property-value",
    "stream-reader/create-stream-reader",
)

CLASS_NAME_OVERRIDES = {
    "list": "object-list",
}

CLASS_OVERRIDES = {
    "instance": ClassOverride(
        constructor_defaults=(
            (
                "builder",
                "(let ((builder (make-instance 'instance-builder))) "
                "(setf (module-path builder) (native-library-directory)) "
                "builder)",
            ),
        )
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
        specializer="managed-object",
        optional_defaults=(("search-filter", "nil"),),
    ),
    "function-block/get-signals-recursive": FunctionOverride(
        specializer="managed-object",
        optional_defaults=(("search-filter", "nil"),),
    ),
    "component/find-component": FunctionOverride(specializer="managed-object"),
    "property-object/get-property-value": FunctionOverride(specializer="managed-object"),
    "property-object/set-property-value": FunctionOverride(specializer="managed-object"),
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


def input_parameters(function: FunctionInfo) -> tuple[ParameterInfo, ...]:
    return tuple(
        parameter
        for parameter in function.parameters
        if parameter_mode(function, parameter) == "in"
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
        if parameter.lisp_name != "obj" and parameter_mode(function, parameter) == "in"
    )


def classify_function(function: FunctionInfo) -> str:
    stem = method_name(function)
    if stem.startswith("create-"):
        return "constructor"
    if stem.startswith("get-"):
        return "reader"
    if stem.startswith("set-"):
        return "writer"
    return "method"


def exposed_name(function: FunctionInfo, kind: str) -> str:
    stem = method_name(function)
    if kind in {"reader", "writer"}:
        return stem.partition("-")[2]
    return stem


def result_parameter(function: FunctionInfo) -> ParameterInfo | None:
    outputs = output_parameters(function)
    if not outputs:
        return None
    if len(outputs) != 1:
        raise ValueError(
            f"{function.public_lisp_name} has {len(outputs)} output parameters; "
            "the high-level generator currently only supports a single result."
        )
    return outputs[0]


def result_class_name(function: FunctionInfo) -> str | None:
    parameter = result_parameter(function)
    if (
        parameter is None
        or parameter.base_lisp_name == "daq-string"
        or not parameter.pointer_like
    ):
        return None
    return class_name_for_type(parameter.base_lisp_name)


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
    if spec.constructor is None:
        return [
            f"(defmethod initialize-instance :after ((object {spec.name})",
            "                                       &key (pointer nil pointer-p)",
            "                                       &allow-other-keys)",
            "  (if pointer-p",
            "      (%adopt-pointer object pointer)",
            f'      (error "{spec.name.upper()} requires :POINTER.")))',
            "",
        ]

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
    lines.extend(
        [
            "                                       &allow-other-keys)",
            "  (cond",
            "    (pointer-p",
        ]
    )
    provided_checks = " ".join(f"{parameter.lisp_name}-p" for parameter in parameters)
    if provided_checks:
        lines.extend(
            [
                f"      (when (or {provided_checks})",
                f'        (error "{spec.name.upper()} cannot be initialized with both :POINTER and constructor arguments."))',
            ]
        )
    lines.append("      (%adopt-pointer object pointer))")

    constructor_call = emit_coerced_call(
        parameters,
        f"(%adopt-pointer object ({LOW_LEVEL_PACKAGE}:{spec.constructor.public_lisp_name} "
        + " ".join(f"coerced-{parameter.lisp_name}" for parameter in parameters)
        + "))",
        indent="      ",
    )

    if required:
        required_checks = " ".join(f"{parameter.lisp_name}-p" for parameter in required)
        lines.append(f"    ((and {required_checks})")
        lines.extend(constructor_call)
        lines.append("      )")
        required_text = " and ".join(f":{parameter.lisp_name.upper()}" for parameter in required)
        lines.append("    (t")
        lines.append(
            f'      (error "{spec.name.upper()} requires either :POINTER or {required_text}."))))'
        )
    else:
        lines.append("    (t")
        lines.extend(constructor_call)
        lines.append("      )))")
    lines.append("")
    return lines


def emit_class_definition(spec: ClassSpec) -> list[str]:
    slots = (
        [
            f"   (%{parameter.lisp_name}-initarg :initarg :{parameter.lisp_name} :initform nil)"
            for parameter in constructor_parameters(spec.constructor)
        ]
        if spec.constructor is not None
        else []
    )
    lines = [f"(defclass {spec.name} (managed-object)", "  ("]
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
    parameters: tuple[ParameterInfo, ...], inner_form: str, indent: str
) -> list[str]:
    lines: list[str] = []

    def recurse(index: int, current_indent: str) -> None:
        if index == len(parameters):
            lines.append(f"{current_indent}{inner_form}")
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


def emit_result_form(function: FunctionInfo, value_form: str) -> str:
    parameter = result_parameter(function)
    if parameter is None:
        return value_form
    if parameter.base_lisp_name == "daq-string":
        return f"(%daq-string-to-lisp-and-release {value_form})"
    class_name = result_class_name(function)
    if class_name is not None:
        return f"(wrap-{class_name} {value_form})"
    return value_form


def indent_lines(lines: list[str], prefix: str) -> list[str]:
    return [f"{prefix}{line}" if line else line for line in lines]


def receiver_form(spec: MethodSpec) -> str:
    if spec.receiver_coercion is not None:
        return "receiver-pointer"
    return "(%require-live-pointer object)"


def wrap_receiver_coercion(spec: MethodSpec, body_lines: list[str]) -> list[str]:
    if spec.receiver_coercion is None:
        return body_lines
    return [
        "  (multiple-value-bind (receiver-pointer cleanup-receiver)",
        "      (%coerce-interface-pointer"
        f" object #'{LOW_LEVEL_PACKAGE}:{spec.receiver_coercion}/get-interface-id"
        f' "{LOW_LEVEL_PACKAGE}:{spec.function.public_lisp_name}")',
        "    (unwind-protect",
        *indent_lines(body_lines, "      "),
        "      (%cleanup-coerced-argument cleanup-receiver)))",
    ]


def emit_reader(spec: MethodSpec) -> list[str]:
    parameters = input_parameters(spec.function)[1:]
    lambda_tail = lambda_list(parameters, spec.optional_defaults)
    generic_tail = generic_lambda_list(parameters, spec.optional_defaults)
    method_tail = (
        f"((object {spec.specializer}){(' ' + lambda_tail) if lambda_tail else ''})"
    )
    call_form = (
        f"({LOW_LEVEL_PACKAGE}:{spec.function.public_lisp_name} {receiver_form(spec)}"
        + "".join(f" coerced-{parameter.lisp_name}" for parameter in parameters)
        + ")"
    )
    lines = [
        f"(defgeneric {spec.name} (object{(' ' + generic_tail) if generic_tail else ''}))",
        f"(defmethod {spec.name} {method_tail}",
    ]
    body_lines = emit_coerced_call(
        parameters,
        emit_result_form(spec.function, call_form),
        indent="" if spec.receiver_coercion is not None else "  ",
    )
    lines.extend(wrap_receiver_coercion(spec, body_lines))
    lines.extend([")", ""])
    return lines


def emit_writer(spec: MethodSpec) -> list[str]:
    parameters = input_parameters(spec.function)[1:]
    if not parameters:
        raise ValueError(f"{spec.function.public_lisp_name} has no writable value.")
    accessor_parameters = parameters[:-1]
    value_parameter = parameters[-1]
    method_tail = (
        f"(new-value (object {spec.specializer})"
        + "".join(f" {parameter.lisp_name}" for parameter in accessor_parameters)
        + ")"
    )
    call_form = (
        f"({LOW_LEVEL_PACKAGE}:{spec.function.public_lisp_name} {receiver_form(spec)}"
        + "".join(
            f" coerced-{parameter.lisp_name}"
            for parameter in accessor_parameters
        )
        + " coerced-new-value)"
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
        call_form,
        indent="" if spec.receiver_coercion is not None else "  ",
    )
    lines.extend(wrap_receiver_coercion(spec, body_lines))
    lines.extend(["  new-value)", ""])
    return lines


def emit_method(spec: MethodSpec) -> list[str]:
    parameters = input_parameters(spec.function)[1:]
    lambda_tail = lambda_list(parameters, spec.optional_defaults)
    generic_tail = generic_lambda_list(parameters, spec.optional_defaults)
    method_tail = (
        f"((object {spec.specializer}){(' ' + lambda_tail) if lambda_tail else ''})"
    )
    call_form = (
        f"({LOW_LEVEL_PACKAGE}:{spec.function.public_lisp_name} {receiver_form(spec)}"
        + "".join(f" coerced-{parameter.lisp_name}" for parameter in parameters)
        + ")"
    )
    lines = [
        f"(defgeneric {spec.name} (object{(' ' + generic_tail) if generic_tail else ''}))",
        f"(defmethod {spec.name} {method_tail}",
    ]
    body_lines = emit_coerced_call(
        parameters,
        emit_result_form(spec.function, call_form),
        indent="" if spec.receiver_coercion is not None else "  ",
    )
    lines.extend(wrap_receiver_coercion(spec, body_lines))
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


def build_specs(functions: dict[str, FunctionInfo]) -> tuple[list[ClassSpec], list[MethodSpec]]:
    selected = []
    for public_name in TARGET_FUNCTIONS:
        function = functions.get(public_name)
        if function is None:
            raise ValueError(f"Required low-level function not found: {public_name}")
        selected.append(function)

    classes: dict[str, ClassSpec] = {}
    methods: list[MethodSpec] = []

    constructors = {function.public_lisp_name: function for function in selected if classify_function(function) == "constructor"}

    for function in selected:
        kind = classify_function(function)
        receiver = receiver_name(function)

        if kind == "constructor":
            class_override = CLASS_OVERRIDES.get(receiver, ClassOverride())
            classes[receiver] = ClassSpec(
                name=receiver,
                constructor=function,
                constructor_defaults=class_override.constructor_defaults,
            )
            continue

        result_class = result_class_name(function)
        if result_class is not None and result_class not in classes:
            class_override = CLASS_OVERRIDES.get(result_class, ClassOverride())
            classes[result_class] = ClassSpec(
                name=result_class,
                constructor=constructors.get(f"{result_class}/create-{result_class}"),
                constructor_defaults=class_override.constructor_defaults,
            )

        override = FUNCTION_OVERRIDES.get(function.public_lisp_name, FunctionOverride())
        methods.append(
            MethodSpec(
                function=function,
                kind=kind,
                name=exposed_name(function, kind),
                specializer=override.specializer or receiver,
                optional_defaults=override.optional_defaults,
                receiver_coercion=override.receiver_coercion,
            )
        )

    if "base-object" not in classes:
        classes["base-object"] = ClassSpec(name="base-object")

    assert_no_managed_object_collisions(methods)
    ordered_classes = sorted(classes.values(), key=lambda spec: spec.name)
    return ordered_classes, methods


def assert_no_managed_object_collisions(methods: list[MethodSpec]) -> None:
    seen: dict[tuple[str, str], str] = {}
    for spec in methods:
        if spec.specializer != "managed-object":
            continue
        key = (spec.kind, spec.name)
        previous = seen.get(key)
        if previous is not None and previous != spec.function.public_lisp_name:
            raise ValueError(
                f"Managed-object dispatch collision for {spec.name}: "
                f"{previous} and {spec.function.public_lisp_name}"
            )
        seen[key] = spec.function.public_lisp_name


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
    function_map = {function.public_lisp_name: function for function in functions}
    classes, methods = build_specs(function_map)

    lines = [
        ";;; This file is autogenerated by tools/generate_high_level_bindings.py.",
        ";;; Do not edit it manually.",
        "",
        "(in-package #:opendaq.high-level)",
        "",
    ]

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

    lines.extend(emit_read_samples_helper())

    exports = export_symbols(classes, methods)
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
