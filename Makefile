PYTHON ?= python3
OPENDAQ_RUNTIME_TRIPLE ?= linux-x64
LISP_BIN_DIR := $(CURDIR)/bin
TMP_DIR := $(CURDIR)/tmp
GENERATED_BINDINGS_DIR := $(CURDIR)/generated
GENERATED_LOW_LEVEL_BINDINGS := $(GENERATED_BINDINGS_DIR)/low-level-bindings.lisp
GENERATED_HIGH_LEVEL_BINDINGS := $(GENERATED_BINDINGS_DIR)/high-level-bindings.lisp
NATIVE_MANIFEST := $(CURDIR)/native-binaries.sexp

# The bindings are generated from the openDAQ API spec (opendaq.json) of one release of
# the opendaq-bindings-nightly repository, and load the C bindings libraries of that same
# release.  opendaq-nightly.lock says which; nothing here builds or even clones openDAQ.

.PHONY: bindings bump-nightly natives repl test clean

# Regenerate generated/ and native-binaries.sexp from the pinned nightly.
bindings:
	@set -e; \
	spec=$$($(PYTHON) tools/fetch_nightly.py); \
	mkdir -p $(GENERATED_BINDINGS_DIR); \
	$(PYTHON) tools/generate_low_level_bindings.py --spec "$$spec" --output $(GENERATED_LOW_LEVEL_BINDINGS); \
	$(PYTHON) tools/generate_high_level_bindings.py --spec "$$spec" --output $(GENERATED_HIGH_LEVEL_BINDINGS); \
	$(PYTHON) tools/write_native_manifest.py "$$(dirname "$$spec")/manifest.json" $(NATIVE_MANIFEST); \
	echo "regenerated from $$(basename "$$(dirname "$$spec")")"

# Move the pin to another nightly and regenerate:
#   make bump-nightly TAG=nightly-20261110-0e29cce-10aaf38
bump-nightly:
	@test -n "$(TAG)" || { echo "usage: make bump-nightly TAG=<release tag>"; exit 1; }
	$(PYTHON) tools/fetch_nightly.py --pin $(TAG) > /dev/null
	$(MAKE) bindings

# Download the pinned native libraries into bin/<platform>/, where the loader looks before
# its download cache.  Optional: without it the loader downloads them on first load.
natives:
	@set -e; \
	spec=$$($(PYTHON) tools/fetch_nightly.py --natives $(OPENDAQ_RUNTIME_TRIPLE)); \
	mkdir -p $(LISP_BIN_DIR)/$(OPENDAQ_RUNTIME_TRIPLE); \
	cp -a "$$(dirname "$$spec")/natives/$(OPENDAQ_RUNTIME_TRIPLE)/." $(LISP_BIN_DIR)/$(OPENDAQ_RUNTIME_TRIPLE)/; \
	ls $(LISP_BIN_DIR)/$(OPENDAQ_RUNTIME_TRIPLE)

repl:
	sbcl --noinform \
	  --eval '(require :asdf)' \
	  --eval '(ql:quickload :cffi :silent t)' \
	  --eval '(ql:quickload :trivial-garbage :silent t)' \
	  --eval '(ql:quickload :local-time :silent t)' \
	  --eval '(asdf:load-asd (truename "opendaq.asd"))' \
	  --eval '(asdf:load-system :opendaq)' \
	  --eval '(in-package #:opendaq.high-level)'

test:
	sbcl --noinform --non-interactive \
	  --eval '(require :asdf)' \
	  --eval '(ql:quickload :cffi :silent t)' \
	  --eval '(ql:quickload :fiveam :silent t)' \
	  --eval '(ql:quickload :trivial-garbage :silent t)' \
	  --eval '(ql:quickload :local-time :silent t)' \
	  --eval '(asdf:load-asd (truename "opendaq.asd"))' \
	  --eval '(asdf:test-system :opendaq)'

clean:
	rm -rf $(LISP_BIN_DIR) $(TMP_DIR)
