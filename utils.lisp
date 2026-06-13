(in-package #:opendaq.low-level)

(cffi:defcfun ("daqClearErrorInfo" %daq-clear-error-info) :void)

(defun %release-object (pointer)
  (when (and pointer (not (cffi:null-pointer-p pointer)))
    (base-object/release-ref pointer))
  nil)

(defmacro with-daq-objects ((&rest objects) &body body)
  `(let ,(mapcar (lambda (object) `(,object nil)) objects)
     (unwind-protect
         (progn ,@body)
       ,@(loop for object in (reverse objects)
               collect `(%release-object ,object)))))

(defun clear-error-info ()
  (ensure-opendaq-loaded)
  (%daq-clear-error-info)
  nil)

(defun make-daq-string (value)
  (cffi:with-foreign-string (cstring value)
    (string/create-string cstring)))
