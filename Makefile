LISP_BIN_DIR := $(CURDIR)/bin
OPENDAQ_RUNTIME_TRIPLE ?= linux-x64
OPENDAQ_RUNTIME_DIR := $(LISP_BIN_DIR)/$(OPENDAQ_RUNTIME_TRIPLE)
TMP_DIR := $(CURDIR)/tmp
OPENDAQ_SRC_DIR := $(TMP_DIR)/openDAQ
OPENDAQ_BUILD_DIR := $(TMP_DIR)/build
PYTHON ?= python3
JOBS ?= $(shell nproc 2>/dev/null || echo 4)
OPENDAQ_REPO_URL ?= https://github.com/openDAQ/openDAQ.git
OPENDAQ_REF ?= release/3.40
GENERATED_BINDINGS := $(CURDIR)/generated/bindings.lisp
GENERATED_HIGH_LEVEL_BINDINGS := $(CURDIR)/generated/high-level-bindings.lisp

.PHONY: bindings repl test clean

bindings:
	rm -rf $(TMP_DIR) $(LISP_BIN_DIR)
	mkdir -p $(TMP_DIR) $(OPENDAQ_RUNTIME_DIR) $(dir $(GENERATED_BINDINGS))
	git clone $(OPENDAQ_REPO_URL) $(OPENDAQ_SRC_DIR)
	git -C $(OPENDAQ_SRC_DIR) checkout --force $(OPENDAQ_REF)
	cmake -S $(OPENDAQ_SRC_DIR) -B $(OPENDAQ_BUILD_DIR) \
	  -DOPENDAQ_GENERATE_C_BINDINGS=ON \
	  -DOPENDAQ_GENERATE_PYTHON_BINDINGS=OFF \
	  -DOPENDAQ_GENERATE_DELPHI_BINDINGS=OFF \
	  -DOPENDAQ_GENERATE_CSHARP_BINDINGS=OFF \
	  -DDAQMODULES_REF_DEVICE_MODULE=ON \
	  -DOPENDAQ_ENABLE_TESTS=OFF \
	  -DOPENDAQ_ENABLE_TEST_UTILS=OFF \
	  -DOPENDAQ_ENABLE_ACCESS_CONTROL=OFF \
	  -DOPENDAQ_ENABLE_NATIVE_STREAMING=ON \
	  -DDAQMODULES_OPENDAQ_CLIENT_MODULE=ON \
	  -DDAQMODULES_REF_DEVICE_MODULE=ON \
	  -DBOOST_LOCALE_ENABLE_ICU=OFF
	cmake --build $(OPENDAQ_BUILD_DIR) -j$(JOBS)
	cp -a $(OPENDAQ_BUILD_DIR)/bin/*.so $(OPENDAQ_RUNTIME_DIR)/
	make regenerate-bindings

regenerate-bindings:
	$(PYTHON) $(CURDIR)/tools/generate_bindings.py --include-dir $(OPENDAQ_SRC_DIR)/bindings/c/include --output $(GENERATED_BINDINGS)
	$(PYTHON) $(CURDIR)/tools/generate_high_level_bindings.py --output $(GENERATED_HIGH_LEVEL_BINDINGS)

repl:
	OPENDAQ_MODULES_PATH=$$(if [ -d "$(OPENDAQ_RUNTIME_DIR)" ]; then printf %s "$(OPENDAQ_RUNTIME_DIR)"; else printf %s "$(LISP_BIN_DIR)"; fi) sbcl --noinform \
	  --eval '(require :asdf)' \
	  --eval '(ql:quickload :cffi :silent t)' \
	  --eval '(ql:quickload :trivial-garbage :silent t)' \
	  --eval '(asdf:load-asd (truename "opendaq.asd"))' \
	  --eval '(asdf:load-system :opendaq)' \
	  --eval '(in-package #:opendaq.high-level)'

test:
	OPENDAQ_MODULES_PATH=$$(if [ -d "$(OPENDAQ_RUNTIME_DIR)" ]; then printf %s "$(OPENDAQ_RUNTIME_DIR)"; else printf %s "$(LISP_BIN_DIR)"; fi) sbcl --noinform --non-interactive \
	  --eval '(require :asdf)' \
	  --eval '(ql:quickload :cffi :silent t)' \
	  --eval '(ql:quickload :fiveam :silent t)' \
	  --eval '(ql:quickload :trivial-garbage :silent t)' \
	  --eval '(asdf:load-asd (truename "opendaq.asd"))' \
	  --eval '(asdf:test-system :opendaq)'

clean:
	rm -rf $(LISP_BIN_DIR) $(TMP_DIR)
