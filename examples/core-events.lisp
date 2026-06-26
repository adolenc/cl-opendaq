(ql:quickload :opendaq :silent t)

(defparameter *instance* (make-instance 'daq:instance))
(daq:add-device *instance* "daqref://device0")

(defparameter *channel*
  (daq:as (daq:find-component *instance* "Dev/RefDev0/IO/AI/RefCh0") 'daq:channel))

(let* ((core-event (daq:on-core-event (daq:context *instance*)))
       ;; ADD-HANDLER returns the EVENT-HANDLER it created, so we keep it to
       ;; unsubscribe later.
       (handler (daq:add-handler
                 core-event
                 (lambda (sender args)
                   (declare (ignore sender))
                   (let ((event (daq:as args 'daq:core-event-args)))
                     (format t "  ~A: ~A~%"
                             (daq:event-name event)
                             (daq:value-of (gethash "Name" (daq:parameters event))
                                           'daq:daq-string-object)))))))
  ;; While subscribed, each property change is reported by the handler above.
  (format t "subscribed:~%")
  (setf (daq:property-value *channel* "Frequency") 25.0)
  (setf (daq:property-value *channel* "Amplitude") 7.5)

  ;; REMOVE-HANDLER unsubscribes; further changes fire nothing.
  (daq:remove-handler core-event handler)
  (format t "unsubscribed (no lines expected below):~%")
  (setf (daq:property-value *channel* "Frequency") 50.0))
