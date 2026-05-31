(in-package #:opendaq.tests)

(in-suite compile-and-run-suite)

(test test-compile
  (daq.ll:with-daq-objects (str)
    (cffi:with-foreign-string (message "Hello, C bindings!")
      ;; Direct port of bindings/c/tests/compile_and_run/test_compile.c:
      ;; create a daqString, then release it, and require both operations to succeed.
      (setf str (daq.ll:string/create-string message))
      (is (= 0 (daq.ll:base-object/release-ref str))
          "test_compile.c release refcount mismatch")
      (setf str nil))))
