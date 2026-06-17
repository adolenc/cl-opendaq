(ql:quickload '(:opendaq :local-time) :silent t)

(defun timestamp->string (timestamp)
  "Render TIMESTAMP as a readable time-of-day, e.g. \"21:05:28.401836\"."
  (local-time:format-timestring
   nil timestamp
   :format '((:hour 2) ":" (:min 2) ":" (:sec 2) "." (:usec 6))
   :timezone local-time:+utc-zone+))

(defparameter *instance* (make-instance 'daq:instance))
(daq:add-device *instance* "daqref://device0")

(let* ((channels (list (daq:as (daq:find-component *instance* "Dev/RefDev0/IO/AI/RefCh0") 'daq:channel)
                       (daq:as (daq:find-component *instance* "Dev/RefDev0/IO/AI/RefCh1") 'daq:channel)))
       (signal-count (length channels)))
  (setf (daq:property-value (first channels) "Frequency") 0.5
        (daq:property-value (second channels) "Frequency") 2.0)
  (let ((reader (make-instance 'daq:multi-reader
                               :signals (mapcar (lambda (channel) (first (daq:signals channel)))
                                                channels))))
    (loop for attempt below 10 do
      (multiple-value-bind (values domain) (daq:read-with-domain reader 8 :timeout-ms 1000)
        (when (plusp (length (first domain)))
          (let ((timestamps (map 'vector (daq:domain-time-converter reader) (first domain))))
            (format t "~16A~{~14@A~}~%" "timestamp"
                    (loop for i below signal-count collect (format nil "signal ~D" i)))
            (dotimes (k (length timestamps))
              (format t "~16A~{~14,6F~}~%"
                      (timestamp->string (aref timestamps k))
                      (loop for v in values collect (aref v k)))))
          (return)))
      finally (format t "Multi reader did not synchronise in time.~%"))))
