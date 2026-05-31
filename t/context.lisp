(in-package #:opendaq.tests)

;; Direct port of bindings/c/tests/copendaq/test_copendaq_context.cpp.

(in-suite opendaq-context-suite)

(test opendaq-context
  (daq:with-daq-objects (context out-logger out-type-manager out-options out-discovery-servers)
    (setf context (%make-test-context))
    (setf out-logger (daq:context/get-logger context))
    (setf out-type-manager (daq:context/get-type-manager context))
    (setf out-options (daq:context/get-options context))
    (setf out-discovery-servers (daq:context/get-discovery-servers context))
    (is (not (cffi:null-pointer-p out-logger))
        "opendaq/context logger lookup returned null")
    (is (not (cffi:null-pointer-p out-type-manager))
        "opendaq/context type manager lookup returned null")
    (is (not (cffi:null-pointer-p out-options))
        "opendaq/context options lookup returned null")
    (is (not (cffi:null-pointer-p out-discovery-servers))
        "opendaq/context discovery servers lookup returned null")))
