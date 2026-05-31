(in-package #:opendaq.tests)

;; Direct port of bindings/c/tests/copendaq/test_copendaq_logger.cpp.

(in-suite opendaq-logger-suite)

(test opendaq-logger
  (daq:with-daq-objects (sinks sink logger)
    (setf sinks (daq:list/create-list))
    (setf sink (daq:logger-sink/create-std-out-logger-sink))
    (daq:list/push-back sinks sink)
    (setf logger (daq:logger/create-logger sinks :daq-log-level-debug))
    (is (not (cffi:null-pointer-p logger))
        "opendaq/logger Logger returned a null object")
    (is (eq :daq-log-level-debug (daq:logger/get-level logger))
        "opendaq/logger level mismatch")))
