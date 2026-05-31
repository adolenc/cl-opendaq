(in-package #:opendaq.tests)

;; Direct port of bindings/c/tests/copendaq/test_copendaq_logger.cpp.

(in-suite opendaq-logger-suite)

(test opendaq-logger
  (daq.ll:with-daq-objects (sinks sink logger)
    (setf sinks (daq.ll:list/create-list))
    (setf sink (daq.ll:logger-sink/create-std-out-logger-sink))
    (daq.ll:list/push-back sinks sink)
    (setf logger (daq.ll:logger/create-logger sinks :daq-log-level-debug))
    (is (not (cffi:null-pointer-p logger))
        "opendaq/logger Logger returned a null object")
    (is (eq :daq-log-level-debug (daq.ll:logger/get-level logger))
        "opendaq/logger level mismatch")))
