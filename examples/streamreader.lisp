(ql:quickload :opendaq :silent t)

(defparameter *instance* (make-instance 'daq:instance))
(daq:add-device *instance* "daqref://device0")

(let* ((channel (daq:as (daq:find-component *instance* "Dev/RefDev0/IO/AI/RefCh0") 'daq:channel))
       (signal (first (daq:signals (daq:as channel 'daq:channel))))
       (reader (make-instance 'daq:stream-reader :signal signal)))
  (format t "some samples: ~A~%" (daq:read reader 100 :timeout-ms 1000))
  (format t "and more samples: ~A~%" (daq:read reader 100 :timeout-ms 1000))
  (format t "and more still: ~A~%" (daq:read reader 100 :timeout-ms 1000)))
