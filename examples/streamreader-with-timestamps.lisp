(ql:quickload '(:opendaq :local-time) :silent t)

(defun timestamp->string (timestamp)
  "Render TIMESTAMP as e.g. \"2026-06-16 21:03:22.060001 UTC\"."
  (local-time:format-timestring
   nil timestamp
   :format '((:year 4) "-" (:month 2) "-" (:day 2) " "
             (:hour 2) ":" (:min 2) ":" (:sec 2) "." (:usec 6) " UTC")
   :timezone local-time:+utc-zone+))

(defparameter *instance* (make-instance 'daq:instance))
(daq:add-device *instance* "daqref://device0")

(let* ((channel (daq:as (daq:find-component *instance* "Dev/RefDev0/IO/AI/RefCh0") 'daq:channel))
       (signal (first (daq:signals channel)))
       (reader (make-instance 'daq:stream-reader :signal signal)))
  (multiple-value-bind (values domain) (daq:read-with-domain reader 10 :timeout-ms 2000)
    (format t "Read ~D sample~:P:~%" (length values))
    (loop for value across values
          for tick across domain
          do (format t "  ~,6F @ ~A~%"
                     value
                     (timestamp->string (daq:domain-tick->timestamp signal tick))))))
