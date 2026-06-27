(in-package #:opendaq.tests)

;; Direct port of bindings/c/tests/copendaq/test_copendaq_logger.cpp.

(in-suite low-level-logger-suite)

(test opendaq-logger
  (opendaq.low-level:with-daq-objects (sinks sink logger)
    (setf sinks (opendaq.low-level:list/create-list))
    (setf sink (opendaq.low-level:logger-sink/create-std-out-logger-sink))
    (opendaq.low-level:list/push-back sinks sink)
    (setf logger (opendaq.low-level:logger/create-logger sinks :daq-log-level-debug))
    (is (not (cffi:null-pointer-p logger)) "opendaq/logger Logger returned a null object")
    (is (eq :daq-log-level-debug (opendaq.low-level:logger/get-level logger)) "opendaq/logger level mismatch")))
