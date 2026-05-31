(in-package #:opendaq.tests)

(def-suite opendaq-suite
  :description "Standalone low-level openDAQ Lisp bindings tests.")

(def-suite compile-and-run-suite
  :in opendaq-suite
  :description "Direct ports of bindings/c/tests/compile_and_run.")

(def-suite coretypes-suite
  :in opendaq-suite
  :description "Direct ports of the portable subset of bindings/c/tests/coretypes.")

(def-suite smoke-suite
  :in opendaq-suite
  :description "Low-level smoke coverage for generated wrappers and simulator access.")

(defun run-test-suite ()
  (let ((*print-names* t)
        (*on-error* :backtrace)
        (*on-failure* nil))
    (unless (run! 'opendaq-suite)
      (error "FiveAM test suite failed."))
    t))

(defun run-smoke-tests ()
  (run-test-suite))
