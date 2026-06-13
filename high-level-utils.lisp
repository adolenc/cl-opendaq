(in-package #:opendaq.high-level)

(defun as-list (object-list)
  "Convert an openDAQ object-list into a proper Lisp list of wrapped objects.

Items are returned as their base-object wrappers.  Use AS to cast them to a
more specific type when needed:

  (mapcar (lambda (d) (connection-string (as d 'device-info)))
          (as-list (available-devices root-device)))"
  (loop for i below (count object-list)
        collect (item-at object-list i)))

(defun as (object target-type)
  "Reinterpret a base openDAQ object as a more specific type.

Adds a reference so the returned wrapper owns its own lifetime.
TARGET-TYPE is a symbol naming the wrapper class (e.g. 'DEVICE-INFO)."
  (let ((class (if (symbolp target-type)
                   (find-class target-type)
                   target-type)))
    (add-ref object)
    (make-instance class :pointer (raw-pointer object))))

