ROOT_DIR := $(abspath ..)
BUILD_DIR := $(ROOT_DIR)/build-lisp-native
LISP_BIN_DIR := $(CURDIR)/bin
LISP_INCLUDE_DIR := $(CURDIR)/include
SBCL ?= sbcl
CMAKE ?= cmake
PYTHON ?= python3
JOBS ?= $(shell nproc 2>/dev/null || echo 4)
PUBLIC_HEADERS := $(ROOT_DIR)/bindings/c/include
LIBRARY_PATTERNS := libdaqcoretypes*.so libdaqcoreobjects*.so libopendaq*.so libcopendaq*.so libref_device_module*.so
GENERATED_BINDINGS := $(CURDIR)/generated/bindings.lisp

.PHONY: native generate repl smoke clean

native:
	$(CMAKE) -S $(ROOT_DIR) -B $(BUILD_DIR) -DOPENDAQ_GENERATE_C_BINDINGS=ON -DDAQMODULES_REF_DEVICE_MODULE=ON
	$(CMAKE) --build $(BUILD_DIR) --target copendaq ref_device_module -j$(JOBS)
	rm -rf $(LISP_BIN_DIR) $(LISP_INCLUDE_DIR)
	mkdir -p $(LISP_BIN_DIR) $(LISP_INCLUDE_DIR)
	cp -a $(PUBLIC_HEADERS)/. $(LISP_INCLUDE_DIR)/
	for pattern in $(LIBRARY_PATTERNS); do \
		matches="$(BUILD_DIR)/bin/$$pattern"; \
		found=0; \
		for file in $$matches; do \
			if [ -e "$$file" ]; then \
				cp -a "$$file" $(LISP_BIN_DIR)/; \
				found=1; \
			fi; \
		done; \
		if [ "$$found" -eq 0 ]; then \
			echo "Missing native library matching $$pattern in $(BUILD_DIR)/bin" >&2; \
			exit 1; \
		fi; \
	done

generate: native
	mkdir -p $(CURDIR)/generated
	$(PYTHON) $(CURDIR)/tools/generate_bindings.py --include-dir $(LISP_INCLUDE_DIR) --output $(GENERATED_BINDINGS)

repl: generate
	OPENDAQ_MODULES_PATH=$(LISP_BIN_DIR) $(SBCL) --noinform \
	  --eval '(require :asdf)' \
	  --eval '(asdf:load-asd (truename "opendaq.asd"))' \
	  --eval '(asdf:load-system :opendaq)' \
	  --eval '(in-package #:opendaq)'

smoke: generate
	OPENDAQ_MODULES_PATH=$(LISP_BIN_DIR) $(SBCL) --noinform --non-interactive \
	  --eval '(require :asdf)' \
	  --eval '(asdf:load-asd (truename "opendaq.asd"))' \
	  --eval '(asdf:test-system :opendaq)'

clean:
	rm -rf $(LISP_BIN_DIR) $(LISP_INCLUDE_DIR)
