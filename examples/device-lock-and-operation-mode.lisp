(ql:quickload :opendaq :silent t)


(defparameter *instance* (make-instance 'daq:instance))
(defparameter *device* (daq:add-device *instance* "daqref://device0"))

(defun op-mode->string (mode)
  (let ((keyword (if (integerp mode)
                     (cffi:foreign-enum-keyword 'daq:operation-mode-type mode)
                     mode)))
    (remove #\- (string-capitalize (string keyword)))))


(format t "Available operation modes: ~{~A~^, ~}~%" (mapcar #'op-mode->string (daq:available-operation-modes *device*)))
(format t "Current operation mode:    ~A~%" (op-mode->string (daq:operation-mode *device*)))

(setf (daq:operation-mode *device*) :operation)
(daq:lock *device*)
(format t "After setting Operation:   ~A~%" (op-mode->string (daq:operation-mode *device*)))
(format t "Device locked: ~A~%" (daq:is-locked *device*))

(daq:unlock *device*)
(setf (daq:operation-mode *device*) :safe-operation)
(format t "~%Device locked: ~A~%" (daq:is-locked *device*))
(format t "Final operation mode:      ~A~%" (op-mode->string (daq:operation-mode *device*)))
