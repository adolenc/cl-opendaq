(in-package #:opendaq.tests)

(in-suite compile-and-run-suite)

(test test-compile
  (with-daq-objects (str)
    (cffi:with-foreign-string (message "Hello, C bindings!")
      ;; Direct port of bindings/c/tests/compile_and_run/test_compile.c:
      ;; create a daqString, then release it, and require both operations to succeed.
      (setf str (opendaq:string/create-string message))
      (is (= 0 (opendaq:base-object/release-ref str))
          "test_compile.c release refcount mismatch")
      (setf str nil))))
