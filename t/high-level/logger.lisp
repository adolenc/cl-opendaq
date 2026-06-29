(in-package #:opendaq.tests)

(in-suite high-level-logger-suite)

(test high-level-logger-construction
  (let* ((sinks (make-instance 'daq:object-list))
         (sink (make-instance 'daq:logger-sink/std-out)))
    (daq:push-back sinks sink)
    (let ((logger (make-instance 'daq:logger :sinks sinks :level :debug)))
      (is (not (cffi:null-pointer-p (daq:raw-pointer logger))) "High-level loggers should hold a native pointer after construction.")
      (is (eql :debug (daq:level logger)) "High-level loggers should expose the configured log level."))))
