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

;;; Polymorphic bridge methods — when the same generic operates on multiple
;;; sibling specializers (e.g. signals-recursive on both device and
;;; function-block), provide a fallback on their least common ancestor so that
;;; objects returned by find-component & friends still work without manual casting.

(defmethod signals-recursive ((object component) &optional (search-filter nil))
  (multiple-value-bind (coerced-search-filter cleanup-search-filter)
      (%coerce-argument search-filter :managed-pointer)
    (unwind-protect
         (handler-case
             (as-list-of
              (wrap-object-list (opendaq:function-block/get-signals-recursive
                                 (%require-live-pointer object) coerced-search-filter))
              'signal)
           (error ()
             (as-list-of
              (wrap-object-list (opendaq:device/get-signals-recursive
                                 (%require-live-pointer object) coerced-search-filter))
              'signal)))
      (%cleanup-coerced-argument cleanup-search-filter))))