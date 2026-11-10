# Tools

This folder contains the python scripts that generate the bindings lisp files
in the `generated/` folder.

- `fetch_nightly.py` downloads the release of
  [opendaq-bindings-nightly](https://github.com/adolenc/opendaq-bindings-nightly)
  pinned in `opendaq-nightly.lock`: the API spec `opendaq.json` and, on
  request, the native libraries, each verified against the checksums in the
  release's manifest.
- `spec_bindings.py` turns `opendaq.json` into a JSON stream of binding records
  (functions, interfaces, enums, typedefs, error codes).  The spec describes
  the C API exactly as the library exports it and defines every type it uses,
  so nothing is parsed out of a header and the script carries no tables.  See
  the comment at the top of it for the record schema.
- `generate_low_level_bindings.py` and `generate_high_level_bindings.py` are the
  lisp-specific generators working from those records.
- `write_native_manifest.py` derives `native-binaries.sexp` from the release's
  manifest.

`fetch_nightly.py` and `spec_bindings.py` are not lisp-specific; the Java
bindings ([jopendaq](https://github.com/adolenc/jopendaq)) carry the same two
files.
