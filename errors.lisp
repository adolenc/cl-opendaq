(in-package #:opendaq)

(defconstant +daq-success+ 0)
(defconstant +daq-err-invalid-parameter+ #x80000003)
(defconstant +daq-err-invalid-state+ #x80000004)
(defconstant +daq-err-not-found+ #x80000005)
(defconstant +daq-err-not-assigned+ #x80000006)

(defparameter *known-error-codes*
  `((,+daq-success+ . "DAQ_SUCCESS")
    (,+daq-err-invalid-parameter+ . "OPENDAQ_ERR_INVALIDPARAMETER")
    (,+daq-err-invalid-state+ . "OPENDAQ_ERR_INVALIDSTATE")
    (,+daq-err-not-found+ . "OPENDAQ_ERR_NOTFOUND")
    (,+daq-err-not-assigned+ . "OPENDAQ_ERR_NOTASSIGNED")))

(define-condition opendaq-error (error)
  ((code :initarg :code :reader opendaq-error-code)
   (operation :initarg :operation :reader opendaq-error-operation))
  (:report
   (lambda (condition stream)
     (let* ((code (opendaq-error-code condition))
            (name (cdr (assoc code *known-error-codes*))))
       (format stream
               "openDAQ call ~A failed with ~A (~8,'0X)."
               (opendaq-error-operation condition)
               (or name "an unknown error")
               code)))))

(defun %failure-code-p (code)
  (not (zerop (logand code #x80000000))))

(defun %check-error (code operation)
  (when (%failure-code-p code)
    (error 'opendaq-error :code code :operation operation))
  code)
