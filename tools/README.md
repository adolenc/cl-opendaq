# Tools

This folder contains python scripts that generate the bindings lisp files in
the `generated/` folder.

While the `generate_*.py` scripts are relatively lisp-specific, the
`parse_bindings.py` script is a general-purpuse parser that outputs a JSON
stream of the exposed interfaces from the `openDAQ/bindings/c/` header files.
See the comment at the top of the script for more details.
