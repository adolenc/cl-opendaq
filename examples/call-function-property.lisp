;;;; Calling a function/procedure property from Lisp.
;;;;
;;;; Some openDAQ properties don't hold data -- they hold a callable.  A property
;;;; whose value type is FUNC returns a value when invoked; one whose type is
;;;; PROC just performs a side effect.  The reference device carries a tidy
;;;; example: "Protected.Sum", a FUNC property taking two integers (A, B) and
;;;; returning their integer sum.
;;;;
;;;; PROPERTY-VALUE on such a property hands back an ordinary Lisp function:
;;;; FUNCALL it with native Lisp arguments and it boxes them, invokes the openDAQ
;;;; callable, and returns the unboxed result -- no manual argument-list building,
;;;; CALL, or UNBOX in sight.  The argument count is taken from the property's
;;;; callable info and checked before each call.  Arguments are boxed by their
;;;; declared type: a LIST argument (see "Protected.SumList" below) accepts a plain
;;;; Lisp list, and a DICT argument accepts a Lisp hash-table (the reference device
;;;; has no dict-taking property to demonstrate, but the boxing is symmetric).

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
