(ql:quickload :opendaq :silent t)


(defparameter *instance* (make-instance 'daq:instance))
(defparameter *device* (daq:add-device *instance* "daqref://device0"))

(defparameter *sum* (daq:property-value *device* "Protected.Sum"))
(format t "Protected.Sum(7, 5)   = ~A~%" (funcall *sum* 7 5))
(format t "Protected.Sum(40, 2)  = ~A~%" (funcall *sum* 40 2))
(format t "Protected.Sum(100, 1) = ~A~%" (funcall (daq:property-value *device* "Protected.Sum") 100 1))
(format t "Protected.SumList((1 2 3 4)) = ~A~%" (funcall (daq:property-value *device* "Protected.SumList") '(1 2 3 4)))
(format t "Protected.SumList(()) = ~A~%" (funcall (daq:property-value *device* "Protected.SumList") '()))
(handler-case (funcall *sum* 1 2 3)
  (error (e) (format t "~%Wrong arity is rejected: ~A~%" e)))
