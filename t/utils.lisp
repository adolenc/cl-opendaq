(in-package #:opendaq.tests)

(def-suite opendaq-suite
  :description "Standalone low-level openDAQ Lisp bindings tests.")

(def-suite compile-and-run-suite
  :in opendaq-suite
  :description "Direct ports of bindings/c/tests/compile_and_run.")

(def-suite ccoretypes-suite
  :in opendaq-suite
  :description "Direct ports of the portable subset of bindings/c/tests/ccoretypes.")

(def-suite smoke-suite
  :in opendaq-suite
  :description "Low-level smoke coverage for generated wrappers and simulator access.")

(defun %release (pointer)
  (when (and pointer (not (cffi:null-pointer-p pointer)))
    (opendaq:base-object/release-ref pointer))
  nil)

(defmacro with-daq-objects ((&rest objects) &body body)
  `(let ,(mapcar (lambda (object) `(,object nil)) objects)
     (unwind-protect
         (progn ,@body)
       ,@(loop for object in (reverse objects)
               collect `(%release ,object)))))

(defun run-test-suite ()
  (let ((*print-names* t)
        (*on-error* :backtrace)
        (*on-failure* nil))
    (unless (run! 'opendaq-suite)
      (error "FiveAM test suite failed."))
    t))

(defun run-smoke-tests ()
  (run-test-suite))
