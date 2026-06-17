(ql:quickload :opendaq :silent t)

(defparameter *instance* (make-instance 'daq:instance))
(daq:add-device *instance* "daqref://device0")

(daq:add-handler
 (daq:on-core-event (daq:context *instance*))
 (lambda (sender args)
   (declare (ignore sender))
   (let ((event (daq:as args 'daq:core-event-args)))
     (format t "~A: ~A~%"
             (daq:event-name event)
             (daq:value-of (gethash "Name" (daq:parameters event)) 'daq:daq-string-object)))))

(let ((channel (daq:as (daq:find-component *instance* "Dev/RefDev0/IO/AI/RefCh0") 'daq:channel)))
  (setf (daq:property-value channel "Frequency") 25.0)
  (setf (daq:property-value channel "Amplitude") 7.5))
