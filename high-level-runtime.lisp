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

(defmethod initialize-instance :after ((object managed-object)
                                       &key (pointer nil pointer-p)
                                       &allow-other-keys)
  (when pointer-p
    (%adopt-pointer object pointer)))

(defgeneric raw-pointer (object))
(defgeneric release (object))

(defun %release-pointer (pointer)
  (when (and pointer (not (cffi:null-pointer-p pointer)))
    (opendaq.low-level:base-object/release-ref pointer))
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
          (cffi:foreign-string-to-lisp (opendaq.low-level:string/get-char-ptr pointer))
        (%release-pointer pointer))))

(defun %cleanup-coerced-argument (cleanup)
  (when cleanup
    (funcall cleanup))
  nil)

(defun %coerce-argument (value category)
  (flet ((make-cleanup (pointer)
           (lambda ()
             (%release-pointer pointer))))
    (macrolet ((managed-result (raw-value-form)
                 ;; When VALUE is a managed-object, the cleanup closure
                 ;; closes over VALUE to pin it against GC while the raw
                 ;; pointer is in flight during an FFI call.
                 `(cond ((typep value 'managed-object)
                         (let ((raw ,raw-value-form))
                           (values raw
                                   (let ((v value))
                                     (lambda ()
                                       ;; Pin V against GC — SBCL at debug<3
                                       ;; eliminates (declare ignore v) bindings.
                                       v nil)))))
                        ((null value)
                         (values (cffi:null-pointer) nil))
                        (t
                         (values value nil)))))
      (case category
        (:managed-pointer
         (managed-result (%require-live-pointer value)))
        (:daq-string
         (cond ((typep value 'managed-object)
                (let ((raw (%require-live-pointer value)))
                  (values raw (let ((v value))
                                (lambda () v nil)))))
               ((null value)
                (values (cffi:null-pointer) nil))
               ((stringp value)
                (let ((pointer (opendaq.low-level:make-daq-string value)))
                  (values pointer (make-cleanup pointer))))
               ((pathnamep value)
                (let ((pointer (opendaq.low-level:make-daq-string (namestring value))))
                  (values pointer (make-cleanup pointer))))
               (t
                (values value nil))))
        (:daq-base-object
         (cond ((typep value 'managed-object)
                (let ((raw (%require-live-pointer value)))
                  (values raw (let ((v value))
                                (lambda () v nil)))))
               ((stringp value)
                (let ((pointer (opendaq.low-level:make-daq-string value)))
                  (values pointer (make-cleanup pointer))))
               ((pathnamep value)
                (let ((pointer (opendaq.low-level:make-daq-string (namestring value))))
                  (values pointer (make-cleanup pointer))))
               ((floatp value)
                (let ((pointer (opendaq.low-level:float-object/create-float
                                (coerce value 'double-float))))
                  (values pointer (make-cleanup pointer))))
               ((integerp value)
                (let ((pointer (opendaq.low-level:integer/create-integer value)))
                  (values pointer (make-cleanup pointer))))
               ((or (eq value t) (null value))
                (let ((pointer (opendaq.low-level:boolean/create-bool-object
                                (if value 1 0))))
                  (values pointer (make-cleanup pointer))))
               (t
                (values value nil))))
        (:daq-bool
         (values (if value 1 0) nil))
        (otherwise
         (values value nil))))))

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

(export '(release raw-pointer primitive-type-p))

(defun primitive-type-p (type-name)
  "Return T if TYPE-NAME names a boxed primitive (integer, boolean,
float, number, string, ratio, or complex-number) rather than
a full managed-object class like DEVICE or SIGNAL."
  (member type-name '(daq-boolean daq-float daq-integer daq-number
                      daq-ratio daq-string-object complex-number)))

(defun %unbox-primitive (object target-type)
  "Extract the Lisp value from a boxed primitive wrapper and release the
temporary wrapper.  TARGET-TYPE is a symbol naming the primitive class
(e.g. DAQ-INTEGER)."
  (let ((ptr (raw-pointer object)))
    (flet ((finish (value)
             (release object)
             value))
      (ecase target-type
        (daq-boolean        (finish (not (zerop (opendaq.low-level:boolean/get-value ptr)))))
        (daq-float          (finish (opendaq.low-level:float-object/get-value ptr)))
        (daq-integer        (finish (opendaq.low-level:integer/get-value ptr)))
        (daq-number         (finish (opendaq.low-level:number/get-float-value ptr)))
        (daq-ratio          (finish (let ((num (opendaq.low-level:ratio/get-numerator ptr))
                                          (den (opendaq.low-level:ratio/get-denominator ptr)))
                                      (/ num den))))
        (daq-string-object  (prog1
                                (cffi:foreign-string-to-lisp
                                 (opendaq.low-level:string/get-char-ptr ptr))
                              (%release-pointer ptr)
                              (setf (%release-state object) nil)
                              (%cancel-finalizer object)
                              (setf (%pointer object) (cffi:null-pointer))))
        (complex-number     (finish (complex (opendaq.low-level:complex-number/get-real ptr)
                                             (opendaq.low-level:complex-number/get-imaginary ptr))))))))
