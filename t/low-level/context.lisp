(in-package #:opendaq.tests)

;; Direct port of bindings/c/tests/copendaq/test_copendaq_context.cpp.

(in-suite low-level-context-suite)

(test opendaq-context
  (opendaq.low-level:with-daq-objects (context out-logger out-type-manager out-options out-discovery-servers)
    (setf context (%make-test-context))
    (setf out-logger (opendaq.low-level:context/get-logger context))
    (setf out-type-manager (opendaq.low-level:context/get-type-manager context))
    (setf out-options (opendaq.low-level:context/get-options context))
    (setf out-discovery-servers (opendaq.low-level:context/get-discovery-servers context))
    (is (not (cffi:null-pointer-p out-logger))
        "opendaq/context logger lookup returned null")
    (is (not (cffi:null-pointer-p out-type-manager))
        "opendaq/context type manager lookup returned null")
    (is (not (cffi:null-pointer-p out-options))
        "opendaq/context options lookup returned null")
    (is (not (cffi:null-pointer-p out-discovery-servers))
        "opendaq/context discovery servers lookup returned null")))
