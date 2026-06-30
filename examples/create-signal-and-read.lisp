(ql:quickload :opendaq :silent t)


(defparameter *instance* (make-instance 'daq:instance))

(defparameter *domain-descriptor*
  (let ((builder (make-instance 'daq:data-descriptor-builder)))
    (setf (daq:sample-type builder) :int64
          (daq:name builder) "time"
          (daq:rule builder) (make-instance 'daq:data-rule/linear :delta 1 :start 0))
    (daq:build builder)))

(defparameter *value-descriptor*
  (let ((builder (make-instance 'daq:data-descriptor-builder)))
    (setf (daq:sample-type builder) :float64
          (daq:name builder) "values")
    (daq:build builder)))

(defparameter *domain-signal* (make-instance 'daq:signal-config :context (daq:context *instance*) :parent nil :local-id "time" :class-name nil))
(setf (daq:descriptor *domain-signal*) *domain-descriptor*)
(defparameter *signal* (make-instance 'daq:signal-config :context (daq:context *instance*) :parent nil :local-id "values" :class-name nil))
(setf (daq:descriptor *signal*) *value-descriptor*
      (daq:domain-signal *signal*) *domain-signal*)

(defparameter *reader* (make-instance 'daq:stream-reader :signal *signal* :timeout-type :any))

(defun send-chunk (offset samples)
  "Send SAMPLES (a list of reals) as one packet whose implicit domain ticks start
at OFFSET."
  (let* ((count (length samples))
         (domain-packet (make-instance 'daq:data-packet :descriptor *domain-descriptor* :sample-count count :offset offset))
         (packet (make-instance 'daq:data-packet/with-domain :domain-packet domain-packet :descriptor *value-descriptor* :sample-count count :offset 0)))
    (setf (daq:data packet) samples)
    (daq:send-packet *signal* packet)))


(send-chunk 0 #(1.1 2.2 3.3 4.4))
(send-chunk 4 #(5.5 6.6 7.7 8.8))
(send-chunk 8 #(9.9 10.0))

(multiple-value-bind (values ticks) (daq:read-with-domain *reader* 100 :timeout-ms 1000)
  (format t "Read ~D sample~:P:~%" (length values))
  (loop for value across values
        for tick across ticks
        do (format t "  tick ~2D -> ~,1F~%" tick value)))
