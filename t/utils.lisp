(in-package #:opendaq.tests)

(def-suite opendaq-suite
  :description "Standalone low-level openDAQ Lisp bindings tests.")

(def-suite compile-and-run-suite
  :in opendaq-suite
  :description "Direct ports of bindings/c/tests/compile_and_run.")

(def-suite coretypes-suite
  :in opendaq-suite
  :description "Direct ports of the portable subset of bindings/c/tests/coretypes.")

(def-suite coreobjects-suite
  :in opendaq-suite
  :description "Direct ports of the portable subset of bindings/c/tests/coreobjects.")

(def-suite opendaq-runtime-suite
  :in opendaq-suite
  :description "Direct ports of the portable subset of bindings/c/tests/copendaq.")

(def-suite opendaq-api-suite
  :in opendaq-runtime-suite
  :description "Portable ports of test_copendaq_opendaq.cpp.")

(def-suite opendaq-context-suite
  :in opendaq-runtime-suite
  :description "Portable ports of test_copendaq_context.cpp.")

(def-suite opendaq-logger-suite
  :in opendaq-runtime-suite
  :description "Portable ports of test_copendaq_logger.cpp.")

(def-suite opendaq-device-suite
  :in opendaq-runtime-suite
  :description "Portable ports of test_copendaq_device.cpp.")

(def-suite opendaq-component-suite
  :in opendaq-runtime-suite
  :description "Portable ports of test_copendaq_component.cpp.")

(def-suite opendaq-streaming-suite
  :in opendaq-runtime-suite
  :description "Portable ports of test_copendaq_streaming.cpp.")

(def-suite opendaq-server-suite
  :in opendaq-runtime-suite
  :description "Portable ports of test_copendaq_server.cpp.")

(def-suite opendaq-signal-suite
  :in opendaq-runtime-suite
  :description "Portable ports of test_copendaq_signal.cpp.")

(def-suite smoke-suite
  :in opendaq-suite
  :description "Low-level smoke coverage for generated wrappers and simulator access.")

(defun %daq-string-value (string)
  (cffi:foreign-string-to-lisp (daq:string/get-char-ptr string)))

(defun %release-daq-object (object)
  (when (and object (not (cffi:null-pointer-p object)))
    (daq:base-object/release-ref object))
  nil)

(defun %make-test-context (&optional (scheduler (cffi:null-pointer)))
  (let ((context nil))
    (daq:with-daq-objects (sinks sink logger type-manager options discovery-servers)
      (setf sinks (daq:list/create-list))
      (setf sink (daq:logger-sink/create-std-err-logger-sink))
      (daq:list/push-back sinks sink)
      (setf logger (daq:logger/create-logger sinks :daq-log-level-debug))
      (setf type-manager (daq:type-manager/create-type-manager))
      (setf options (daq:dict/create-dict))
      (setf discovery-servers (daq:dict/create-dict))
      (setf context
            (daq:context/create-context
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
        (setf instance (daq:instance/create-instance context (cffi:null-pointer)))
      (%release-daq-object context))
    instance))

(defun run-test-suite ()
  (let ((*print-names* t)
        (*on-error* :backtrace)
        (*on-failure* nil))
    (unless (run! 'opendaq-suite)
      (error "FiveAM test suite failed."))
    t))

(defun run-smoke-tests ()
  (run-test-suite))
