(in-package #:opendaq.high-level)

(defclass managed-object ()
  ((%pointer
    :accessor %pointer
    :initarg :pointer
    :initform (cffi:null-pointer))
   (%release-state
    :accessor %release-state
    :initform nil)
   (%release-hook
    :accessor %release-hook
    :initarg :release-hook
    :initform nil)))

(defgeneric raw-pointer (object))
(defgeneric release (object))

(defun %release-pointer (pointer)
  (when (and pointer (not (cffi:null-pointer-p pointer)))
    (opendaq:base-object/release-ref pointer))
  nil)

(defun %consume-release-state (release-state)
  (let ((managed-pointer (and release-state (first release-state)))
        (release-hook (and release-state (second release-state))))
    (when managed-pointer
      (setf (first release-state) nil)
      (%release-pointer managed-pointer)
      (when release-hook
        (funcall release-hook))))
  nil)

(defun %register-finalizer (object thunk)
  (trivial-garbage:finalize object thunk)
  nil)

(defun %cancel-finalizer (object)
  (trivial-garbage:cancel-finalization object)
  nil)

(defun %adopt-pointer (object pointer)
  (when (or (null pointer) (cffi:null-pointer-p pointer))
    (error "Cannot wrap a null openDAQ pointer."))
  (let ((release-state (list pointer (%release-hook object))))
    (setf (%pointer object) pointer
          (%release-state object) release-state)
    (%register-finalizer object
      (lambda ()
        (%consume-release-state release-state)))
    object))

(defun %require-live-pointer (object)
  (let ((pointer (raw-pointer object)))
    (when (or (null pointer) (cffi:null-pointer-p pointer))
      (error "The openDAQ object ~S has already been released." object))
    pointer))

(defun %daq-string-to-lisp-and-release (pointer)
  (if (or (null pointer) (cffi:null-pointer-p pointer))
      nil
      (prog1
          (cffi:foreign-string-to-lisp (opendaq:string/get-char-ptr pointer))
        (%release-pointer pointer))))

(defun %cleanup-coerced-argument (cleanup)
  (when cleanup
    (funcall cleanup))
  nil)

(defun %coerce-argument (value category)
  (flet ((make-cleanup (pointer)
           (lambda ()
             (%release-pointer pointer))))
    (case category
      (:managed-pointer
       (values (cond ((typep value 'managed-object)
                      (%require-live-pointer value))
                     ((null value)
                      (cffi:null-pointer))
                     (t
                      value))
               nil))
      (:daq-string
       (cond ((typep value 'managed-object)
              (values (%require-live-pointer value) nil))
             ((null value)
              (values (cffi:null-pointer) nil))
             ((stringp value)
              (let ((pointer (opendaq:make-daq-string value)))
                (values pointer (make-cleanup pointer))))
             ((pathnamep value)
              (let ((pointer (opendaq:make-daq-string (namestring value))))
                (values pointer (make-cleanup pointer))))
             (t
              (values value nil))))
      (:daq-base-object
       (cond ((typep value 'managed-object)
              (values (%require-live-pointer value) nil))
             ((stringp value)
              (let ((pointer (opendaq:make-daq-string value)))
                (values pointer (make-cleanup pointer))))
             ((pathnamep value)
              (let ((pointer (opendaq:make-daq-string (namestring value))))
                (values pointer (make-cleanup pointer))))
             ((floatp value)
              (let ((pointer (opendaq:float-object/create-float
                              (coerce value 'double-float))))
                (values pointer (make-cleanup pointer))))
             ((integerp value)
              (let ((pointer (opendaq:integer/create-integer value)))
                (values pointer (make-cleanup pointer))))
             ((or (eq value t) (null value))
              (let ((pointer (opendaq:boolean/create-bool-object
                              (if value 1 0))))
                (values pointer (make-cleanup pointer))))
             (t
              (values value nil))))
      (:daq-bool
       (values (if value 1 0) nil))
      (otherwise
       (values value nil)))))

(defmethod raw-pointer ((object managed-object))
  (%pointer object))

(defmethod release ((object managed-object))
  (let* ((release-state (%release-state object))
         (managed-pointer (and release-state (first release-state))))
    (when managed-pointer
      (%cancel-finalizer object)
      (setf (%pointer object) (cffi:null-pointer))
      (%consume-release-state release-state))
    nil))

(export '(release raw-pointer))
