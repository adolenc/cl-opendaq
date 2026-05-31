LISP_BIN_DIR := $(CURDIR)/bin
TMP_DIR := $(CURDIR)/tmp
OPENDAQ_SRC_DIR := $(TMP_DIR)/openDAQ
OPENDAQ_BUILD_DIR := $(TMP_DIR)/build
OPENDAQ_HEADERS_DIR := $(OPENDAQ_SRC_DIR)/bindings/c/include
SBCL ?= sbcl
CMAKE ?= cmake
PYTHON ?= python3
JOBS ?= $(shell nproc 2>/dev/null || echo 4)
GIT ?= git
OPENDAQ_REPO ?= https://github.com/openDAQ/openDAQ.git
OPENDAQ_REF ?= 70104b729126ce17a76b7c795a306570b8a337b5
GENERATED_BINDINGS := $(CURDIR)/generated/bindings.lisp

.PHONY: bindings repl test clean

bindings:
	rm -rf $(TMP_DIR) $(LISP_BIN_DIR)
	mkdir -p $(TMP_DIR) $(LISP_BIN_DIR) $(dir $(GENERATED_BINDINGS))
	$(GIT) clone $(OPENDAQ_REPO) $(OPENDAQ_SRC_DIR)
	$(GIT) -C $(OPENDAQ_SRC_DIR) checkout --force $(OPENDAQ_REF)
	$(CMAKE) -S $(OPENDAQ_SRC_DIR) -B $(OPENDAQ_BUILD_DIR) -DOPENDAQ_GENERATE_C_BINDINGS=ON -DDAQMODULES_REF_DEVICE_MODULE=ON
	$(CMAKE) --build $(OPENDAQ_BUILD_DIR) --target copendaq ref_device_module -j$(JOBS)
	cp -a $(OPENDAQ_BUILD_DIR)/bin/*.so $(LISP_BIN_DIR)/
	$(PYTHON) $(CURDIR)/tools/generate_bindings.py --include-dir $(OPENDAQ_HEADERS_DIR) --output $(GENERATED_BINDINGS)

repl: bindings
	OPENDAQ_MODULES_PATH=$(LISP_BIN_DIR) $(SBCL) --noinform \
	  --eval '(require :asdf)' \
	  --eval '(asdf:load-asd (truename "opendaq.asd"))' \
	  --eval '(asdf:load-system :opendaq)' \
	  --eval '(in-package #:opendaq)'

test: bindings
	OPENDAQ_MODULES_PATH=$(LISP_BIN_DIR) $(SBCL) --noinform --non-interactive \
	  --eval '(require :asdf)' \
	  --eval '(asdf:load-asd (truename "opendaq.asd"))' \
	  --eval '(asdf:test-system :opendaq)'

clean:
	rm -rf $(LISP_BIN_DIR) $(TMP_DIR)
