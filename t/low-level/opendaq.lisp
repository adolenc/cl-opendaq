(in-package #:opendaq.tests)

;; Direct port of the portable subset of bindings/c/tests/copendaq/test_copendaq_opendaq.cpp.

(in-suite low-level-api-suite)

(test opendaq-config-provider
  (opendaq.low-level:with-daq-objects (config-provider)
    (setf config-provider (opendaq.low-level:config-provider/create-env-config-provider))
    (is (not (cffi:null-pointer-p config-provider))
        "opendaq/opendaq ConfigProvider returned a null object")))

(test opendaq-instance-and-builder
  (opendaq.low-level:with-daq-objects (builder instance)
    (setf builder (opendaq.low-level:instance-builder/create-instance-builder))
    (is (not (cffi:null-pointer-p builder))
        "opendaq/opendaq InstanceBuilder returned a null object")
    (setf instance (%make-test-instance))
    (is (not (cffi:null-pointer-p instance))
        "opendaq/opendaq Instance returned a null object")))
