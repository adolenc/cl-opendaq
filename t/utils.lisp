(in-package #:opendaq.tests)

(def-suite low-level-suite
  :description "Standalone low-level openDAQ Lisp bindings tests.")

(def-suite low-level-compile-and-run-suite
  :in low-level-suite
  :description "Direct ports of bindings/c/tests/compile_and_run.")

(def-suite low-level-coretypes-suite
  :in low-level-suite
  :description "Direct ports of the portable subset of bindings/c/tests/coretypes.")

(def-suite low-level-coreobjects-suite
  :in low-level-suite
  :description "Direct ports of the portable subset of bindings/c/tests/coreobjects.")

(def-suite low-level-runtime-suite
  :in low-level-suite
  :description "Direct ports of the portable subset of bindings/c/tests/copendaq.")

(def-suite low-level-api-suite
  :in low-level-runtime-suite
  :description "Portable ports of test_copendaq_opendaq.cpp.")

(def-suite low-level-context-suite
  :in low-level-runtime-suite
  :description "Portable ports of test_copendaq_context.cpp.")

(def-suite low-level-logger-suite
  :in low-level-runtime-suite
  :description "Portable ports of test_copendaq_logger.cpp.")

(def-suite low-level-device-suite
  :in low-level-runtime-suite
  :description "Portable ports of test_copendaq_device.cpp.")

(def-suite low-level-component-suite
  :in low-level-runtime-suite
  :description "Portable ports of test_copendaq_component.cpp.")

(def-suite low-level-streaming-suite
  :in low-level-runtime-suite
  :description "Portable ports of test_copendaq_streaming.cpp.")

(def-suite low-level-server-suite
  :in low-level-runtime-suite
  :description "Portable ports of test_copendaq_server.cpp.")

(def-suite low-level-signal-suite
  :in low-level-runtime-suite
  :description "Portable ports of test_copendaq_signal.cpp.")

(def-suite low-level-smoke-suite
  :in low-level-suite
  :description "Low-level smoke coverage for generated wrappers and simulator access.")

(def-suite high-level-suite
  :in low-level-suite
  :description "High-level wrapper coverage for the generated bindings layer.")

(def-suite high-level-compile-suite
  :in high-level-suite
  :description "High-level coverage mirroring the compile-and-run smoke check.")

(def-suite high-level-coretypes-suite
  :in high-level-suite
  :description "High-level coverage mirroring the core types suite.")

(def-suite high-level-coreobjects-suite
  :in high-level-suite
  :description "High-level coverage mirroring the core objects suite.")

(def-suite high-level-runtime-suite
  :in high-level-suite
  :description "High-level coverage mirroring the runtime suite.")

(def-suite high-level-opendaq-api-suite
  :in high-level-runtime-suite
  :description "High-level coverage mirroring the openDAQ API suite.")

(def-suite high-level-context-suite
  :in high-level-runtime-suite
  :description "High-level coverage mirroring the context suite.")

(def-suite high-level-logger-suite
  :in high-level-runtime-suite
  :description "High-level coverage mirroring the logger suite.")

(def-suite high-level-device-suite
  :in high-level-runtime-suite
  :description "High-level coverage mirroring the device suite.")

(def-suite high-level-component-suite
  :in high-level-runtime-suite
  :description "High-level coverage mirroring the component suite.")

(def-suite high-level-streaming-suite
  :in high-level-runtime-suite
  :description "High-level coverage mirroring the streaming suite.")

(def-suite high-level-server-suite
  :in high-level-runtime-suite
  :description "High-level coverage mirroring the server suite.")

(def-suite high-level-signal-suite
  :in high-level-runtime-suite
  :description "High-level coverage mirroring the signal suite.")

(def-suite high-level-smoke-suite
  :in high-level-suite
  :description "High-level smoke coverage for generated wrappers and simulator access.")

(defun %daq-string-value (string)
  (cffi:foreign-string-to-lisp (daq.ll:string/get-char-ptr string)))

(defun %release-daq-object (object)
  (when (and object (not (cffi:null-pointer-p object)))
    (daq.ll:base-object/release-ref object))
  nil)

(defun %boxed-string-value (object)
  (%daq-string-value (daq:raw-pointer object)))

(defun %boxed-integer-value (object)
  (daq.ll:integer/get-value (daq:raw-pointer object)))

(defun %boxed-boolean-value (object)
  (not (zerop (daq.ll:boolean/get-value (daq:raw-pointer object)))))

(defun %make-test-context (&optional (scheduler (cffi:null-pointer)))
  (let ((context nil))
    (daq.ll:with-daq-objects (sinks sink logger type-manager options discovery-servers)
      (setf sinks (daq.ll:list/create-list))
      (setf sink (daq.ll:logger-sink/create-std-err-logger-sink))
      (daq.ll:list/push-back sinks sink)
      (setf logger (daq.ll:logger/create-logger sinks :daq-log-level-debug))
      (setf type-manager (daq.ll:type-manager/create-type-manager))
      (setf options (daq.ll:dict/create-dict))
      (setf discovery-servers (daq.ll:dict/create-dict))
      (setf context
            (daq.ll:context/create-context
             scheduler
             logger
             type-manager
             (cffi:null-pointer)
             (cffi:null-pointer)
             options
             discovery-servers)))
    context))

(defun %make-test-instance ()
  (let ((context (%make-test-context))
        (instance nil))
    (unwind-protect
        (setf instance (daq.ll:instance/create-instance context (cffi:null-pointer)))
      (%release-daq-object context))
    instance))

(defun run-test-suite ()
  (let ((*print-names* t)
        (*on-error* :backtrace)
        (*on-failure* nil))
    (unless (run! 'low-level-suite)
      (error "FiveAM test suite failed."))
    t))

(defun run-smoke-tests ()
  (run-test-suite))
