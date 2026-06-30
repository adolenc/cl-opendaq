;;;; openDAQ runtime support layer.
;;;;
;;;; Hand-written code loaded between the generated low-level and high-level
;;;; bindings.  Consolidates what used to be loader.lisp, errors.lisp,
;;;; utils.lisp and high-level-runtime.lisp.  The first three sections are in
;;;; the OPENDAQ.LOW-LEVEL package; the last switches to OPENDAQ.HIGH-LEVEL.

(in-package #:opendaq.low-level)

;;; ===========================================================================
;;; Native library loader (was loader.lisp)
;;; ===========================================================================

(eval-when (:compile-toplevel :load-toplevel :execute)
  #+sbcl
  (require :sb-posix))

(defparameter +native-directory-env-var+ "OPENDAQ_LISP_NATIVE_DIR")
(defparameter +modules-directory-env-var+ "OPENDAQ_MODULES_PATH")

(defparameter +native-library-file-names+
  ;; Exact file names shipped in bin/<platform>/, in dependency load order.
  #+linux
  '("libdaqcoretypes-64-3.so"
    "libdaqcoreobjects-64-3.so"
    "libopendaq-64-3.so"
    "libcopendaq.so")
  #+darwin
  '("libdaqcoretypes-64-3.dylib"
    "libdaqcoreobjects-64-3.dylib"
    "libopendaq-64-3.dylib"
    "libcopendaq.dylib")
  #+(or windows win32)
  '("daqcoretypes-64-3.dll"
    "daqcoreobjects-64-3.dll"
    "opendaq-64-3.dll"
    "copendaq.dll")
  #-(or linux darwin windows win32)
  (error "Unsupported OS for openDAQ native libraries: ~A" (software-type)))

(defvar *loaded-native-directory* nil)
(defvar *loaded-library-paths* nil)
(defvar *autoload-attempted-p* nil)
(defvar *autoload-error* nil)

(defun %directory-if-exists (path)
  (let ((directory (uiop:ensure-directory-pathname path)))
    (when (probe-file directory)
      directory)))

(defun %environment-native-directory ()
  (let ((value (uiop:getenv +native-directory-env-var+)))
    (when (and value (plusp (length value)))
      (or (%directory-if-exists value)
          (error
           "The ~A override points to a missing directory: ~A"
           +native-directory-env-var+
           value)))))

(defun %system-native-directory ()
  (ignore-errors (asdf:system-relative-pathname "opendaq" "bin/")))

(defun %current-platform-directory-name ()
  "Name of the bin/ subdirectory holding this host's native libraries, e.g.
\"linux-x64\".  The OS and architecture are selected from *FEATURES* at read
time rather than sniffed from SOFTWARE-TYPE / MACHINE-TYPE strings."
  (let ((os #+linux "linux"
            #+darwin "darwin"
            #+(or windows win32) "windows"
            #-(or linux darwin windows win32)
            (error "Unsupported OS for openDAQ native libraries: ~A"
                   (software-type)))
        (arch #+(or x86-64 x86_64 amd64) "x64"
              #+(or arm64 aarch64) "arm64"
              #-(or x86-64 x86_64 amd64 arm64 aarch64)
              (error "Unsupported architecture for openDAQ native libraries: ~A"
                     (machine-type))))
    (format nil "~A-~A" os arch)))

(defun %native-search-paths-for-root (root)
  (let ((directory (uiop:ensure-directory-pathname root)))
    (list (merge-pathnames (format nil "~A/" (%current-platform-directory-name))
                           directory)
          directory)))

(defun %candidate-native-directories-for-root (root)
  (remove nil
          (mapcar #'%directory-if-exists
                  (%native-search-paths-for-root root))))

(defun %native-search-roots ()
  (remove nil (list (%environment-native-directory) (%system-native-directory))))

(defun %candidate-native-directories ()
  (remove-duplicates
   (mapcan #'%candidate-native-directories-for-root (%native-search-roots))
   :test #'equal
   :key #'namestring))

(defun %configured-native-search-paths ()
  (remove-duplicates
   (mapcan #'%native-search-paths-for-root (%native-search-roots))
   :test #'equal
   :key #'namestring))

(defun %resolve-library-path (directory file-name)
  (or (probe-file (merge-pathnames file-name directory))
      (if (search "copendaq" file-name)
          (error
           "Could not find ~A in ~A. Build openDAQ with OPENDAQ_GENERATE_C_BINDINGS=ON so the C wrapper library is produced."
           file-name (namestring directory))
          (error
           "Could not find ~A in ~A." file-name (namestring directory)))))

(defun native-library-directory ()
  (or (first (%candidate-native-directories))
      (error
       "Unable to locate openDAQ native libraries. Checked ~{~A~^, ~}. Set ~A to override the search path."
       (mapcar #'namestring (%configured-native-search-paths))
       +native-directory-env-var+)))

(defun %load-native-library (path)
  (cffi:load-foreign-library path)
  (namestring path))

(defun ensure-opendaq-loaded (&optional (directory (native-library-directory)))
  (let ((resolved-directory (uiop:ensure-directory-pathname directory)))
    (setf *autoload-attempted-p* t)
    (cond
      ((and *loaded-native-directory*
           (equal (namestring *loaded-native-directory*)
                  (namestring resolved-directory)))
       *loaded-library-paths*)
      (*loaded-native-directory*
       (error
        "openDAQ native libraries are already loaded from ~A and cannot be reloaded from ~A in the same image."
        (namestring *loaded-native-directory*)
        (namestring resolved-directory)))
      (t
       (setf *loaded-library-paths*
             (mapcar (lambda (file-name)
                       (%load-native-library
                        (%resolve-library-path resolved-directory file-name)))
                     +native-library-file-names+)
             *loaded-native-directory* resolved-directory
             *autoload-error* nil)))))

(defun %condition-string (condition)
  (when condition
    (with-output-to-string (stream)
      (princ condition stream))))

(defun %healthcheck-candidate-entries (source root)
  (when root
    (mapcar (lambda (path)
             (list :source source
                   :path (namestring path)
                   :exists (not (null (%directory-if-exists path)))))
           (%native-search-paths-for-root root))))

(defun %healthcheck-candidates ()
  (let ((environment-value (uiop:getenv +native-directory-env-var+)))
    (append (%healthcheck-candidate-entries
            :environment
            (and environment-value
                 (plusp (length environment-value))
                 (uiop:ensure-directory-pathname environment-value)))
           (%healthcheck-candidate-entries
            :system-bin
            (%system-native-directory)))))

(defun %healthcheck-library-status (directory)
  (when directory
    (mapcar (lambda (file-name)
             (handler-case
                 (list :name file-name
                       :ok t
                       :path (namestring (%resolve-library-path directory file-name)))
               (error (condition)
                 (list :name file-name
                       :ok nil
                       :error (%condition-string condition)))))
           +native-library-file-names+)))

(defun healthcheck (&optional (stream *standard-output*))
  (let* ((resolved-directory
          (or *loaded-native-directory*
              (ignore-errors (native-library-directory))))
        (report
          (list :status (cond
                          (*loaded-native-directory* :loaded)
                          (*autoload-error* :autoload-failed)
                          (t :not-loaded))
                :autoload-attempted *autoload-attempted-p*
                :loaded-native-directory
                (and *loaded-native-directory*
                     (namestring *loaded-native-directory*))
                :resolved-native-directory
                (and resolved-directory (namestring resolved-directory))
                :module-path (uiop:getenv +modules-directory-env-var+)
                :loaded-library-paths (copy-list *loaded-library-paths*)
                :autoload-error (%condition-string *autoload-error*)
                :candidates (%healthcheck-candidates)
                :libraries (%healthcheck-library-status resolved-directory))))
    (when stream
      (format stream "~&openDAQ healthcheck~%")
      (format stream "  status: ~A~%" (getf report :status))
      (format stream "  autoload attempted: ~:[no~;yes~]~%"
             (getf report :autoload-attempted))
      (when (getf report :loaded-native-directory)
       (format stream "  loaded native directory: ~A~%"
               (getf report :loaded-native-directory)))
      (when (getf report :resolved-native-directory)
       (format stream "  resolved native directory: ~A~%"
               (getf report :resolved-native-directory)))
      (when (getf report :module-path)
       (format stream "  OPENDAQ_MODULES_PATH: ~A~%"
               (getf report :module-path)))
      (dolist (candidate (getf report :candidates))
       (format stream "  candidate ~A: ~A (~A)~%"
               (getf candidate :source)
               (getf candidate :path)
               (if (getf candidate :exists) "exists" "missing")))
      (dolist (library (getf report :libraries))
       (if (getf library :ok)
           (format stream "  library ~A: ~A~%"
                   (getf library :name)
                   (getf library :path))
           (format stream "  library ~A: ERROR: ~A~%"
                   (getf library :name)
                   (getf library :error))))
      (when (getf report :autoload-error)
       (format stream "  autoload error: ~A~%"
               (getf report :autoload-error))))
    report))

(defun %autoload-opendaq ()
  (unless *autoload-attempted-p*
    (handler-case
       (ensure-opendaq-loaded)
      (error (condition)
       (setf *autoload-error* condition)
       nil))))

(eval-when (:load-toplevel :execute)
  (%autoload-opendaq))

;;; ===========================================================================
;;; Error codes and handling (was errors.lisp)
;;; ===========================================================================

;;; --- FFI binding for retrieving the descriptive error message ---------------
(cffi:defcfun ("daqGetErrorInfoMessage" %daq-get-error-info-message) daq-err-code
  (error-message (:pointer daq-string)))

(defun %get-error-message (code)
  "Retrieve the human-readable error message from the openDAQ library.
Returns NIL if no error information is available.
Uses direct FFI calls to avoid re-entering %check-error during error reporting."
  (declare (ignore code))
  (cffi:with-foreign-object (message-slot 'daq-string)
    (let ((stored-code (%daq-get-error-info-message message-slot)))
      (when (%failure-code-p stored-code)
        (let ((msg-ptr (cffi:mem-ref message-slot 'daq-string)))
          (unless (cffi:null-pointer-p msg-ptr)
            (unwind-protect
                 (cffi:with-foreign-object (char-ptr-slot 'daq-const-char-ptr)
                   (let ((err (%daq-string-get-char-ptr msg-ptr char-ptr-slot)))
                     (if (%failure-code-p err)
                         nil
                         (let ((c-str (cffi:mem-ref char-ptr-slot 'daq-const-char-ptr)))
                           (if (cffi:null-pointer-p c-str)
                               nil
                               (cffi:foreign-string-to-lisp c-str))))))
              (base-object/release-ref msg-ptr))))))))

;;; --- Condition and checking -------------------------------------------------

(define-condition opendaq-error (error)
  ((code :initarg :code :reader opendaq-error-code)
   (operation :initarg :operation :reader opendaq-error-operation)
   (message :initarg :message :reader opendaq-error-message :initform nil))
  (:report
   (lambda (condition stream)
     (let* ((code (opendaq-error-code condition))
            (name (cdr (assoc code *known-error-codes*)))
            (detail (opendaq-error-message condition)))
       (format stream
               "openDAQ call ~A failed with ~A (~8,'0X).~@[ ~A~]"
               (opendaq-error-operation condition)
               (or name "an unknown error")
               code
               detail)))))

(defun %failure-code-p (code)
  (not (zerop (logand code #x80000000))))

(defun %check-error (code operation)
  (when (%failure-code-p code)
    (error 'opendaq-error
           :code code
           :operation operation
           :message (%get-error-message code)))
  code)

;;; ===========================================================================
;;; Low-level utilities (was utils.lisp)
;;; ===========================================================================

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
  (cffi:with-foreign-string (cstring value) (string/create-string cstring)))

;;; ===========================================================================
;;; Interface query
;;; ===========================================================================
;;;
;;; daqBaseObject_borrowInterface is generated by the low-level binder, with the
;;; by-value daqIntfID GUID passed per the platform ABI (see
;;; tools/generate_low_level_bindings.py).  We call the *raw* binding here rather
;;; than the checked wrapper, so an unsupported interface yields NIL instead of a
;;; signalled error and we read the error code directly.  borrowInterface adds no
;;; reference, so there is nothing to release.  The raw binding's arity differs
;;; per platform (two :uint64 words vs a pointer), so the call splits the same way.

(defun %supports-interface-p (self interface-id-getter)
  "True if the object at pointer SELF implements the interface whose id
INTERFACE-ID-GETTER writes into a daqIntfID buffer (a low-level
<type>/get-interface-id function)."
  (cffi:with-foreign-object (id '(:struct daq-intf-id))
    (funcall interface-id-getter id)
    (cffi:with-foreign-object (out 'daq-base-object)
      (zerop
       #-(or windows win32)
       (%daq-base-object-borrow-interface self
                                          (cffi:mem-ref id :uint64 0)
                                          (cffi:mem-ref id :uint64 8)
                                          out)
       #+(or windows win32)
       (%daq-base-object-borrow-interface self id out)))))

;;; ===========================================================================
;;; High-level runtime (was high-level-runtime.lisp)
;;; ===========================================================================
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

(defun wrap (pointer target-type)
  "Adopt a raw openDAQ POINTER as a TARGET-TYPE wrapper.

Takes ownership of the reference the C call already handed back -- it does NOT
add a reference -- so this is the correct way to wrap a pointer returned from an
OPENDAQ.LOW-LEVEL call.  Returns NIL for a null pointer.  TARGET-TYPE is a symbol
(or class) naming the wrapper class, e.g. 'BASE-OBJECT.

This is the raw-pointer counterpart to AS: AS reinterprets an already-wrapped
object and adds its own reference; WRAP adopts a bare pointer without one."
  (unless (or (null pointer) (cffi:null-pointer-p pointer))
    (make-instance target-type :pointer pointer)))

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

(defmacro with-daq-boxed-values (bindings &body body)
  "Bind each (VAR VALUE-FORM CATEGORY) of BINDINGS to the boxed representation of
VALUE-FORM (via %COERCE-ARGUMENT with the given CATEGORY), evaluate BODY, then
release every boxed temporary on the way out -- innermost first -- whether BODY
returns normally or unwinds.  A NIL CATEGORY binds VAR to VALUE-FORM verbatim,
with no coercion and no cleanup (for arguments that need no boxing).  This is the
single expansion the generated high-level wrappers use to marshal their
arguments; see EMIT_COERCED_CALL in tools/generate_high_level_bindings.py."
  (if (null bindings)
      `(progn ,@body)
      (destructuring-bind ((var value-form category) . rest) bindings
        (if (null category)
            `(let ((,var ,value-form))
               (with-daq-boxed-values ,rest ,@body))
            (let ((cleanup (gensym "CLEANUP-")))
              `(multiple-value-bind (,var ,cleanup)
                   (%coerce-argument ,value-form ,category)
                 (unwind-protect
                     (with-daq-boxed-values ,rest ,@body)
                   (%cleanup-coerced-argument ,cleanup))))))))

(defun %query-number-interface (pointer)
  "Return the INumber interface pointer of POINTER, a daq object that implements
INumber (Integer and Float do; Ratio does not).  openDAQ's C ABI requires a genuine
INumber pointer where a Number is expected -- a raw IInteger pointer is not
interface-compatible and corrupts the call -- so the value must be queried, not
merely reinterpreted.  Adds a reference; the caller owns the returned pointer."
  (cffi:with-foreign-object (interface-id :uint64 2)   ; daqIntfID is 16 bytes
    (opendaq.low-level:number/get-interface-id interface-id)
    (opendaq.low-level:base-object/query-interface pointer interface-id)))

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
               ((typep value 'cl:ratio)
                (let ((pointer (opendaq.low-level:ratio/create-ratio
                                (cl:numerator value) (cl:denominator value))))
                  (values pointer (make-cleanup pointer))))
               ((typep value 'cl:complex)
                (let ((pointer (opendaq.low-level:complex-number/create-complex-number
                                (coerce (realpart value) 'double-float)
                                (coerce (imagpart value) 'double-float))))
                  (values pointer (make-cleanup pointer))))
               ((or (eq value t) (null value))
                (let ((pointer (opendaq.low-level:boolean/create-bool-object
                                (if value 1 0))))
                  (values pointer (make-cleanup pointer))))
               (t
                (values value nil))))
        (:daq-number
         ;; openDAQ Number parameters (e.g. a linear data rule's delta/start, or
         ;; a data packet's offset) need a genuine INumber pointer.  Only Integer
         ;; and Float implement INumber (a Ratio is not a Number), so box the Lisp
         ;; value into one of those and query it to INumber; a managed-object is
         ;; queried in place (pinned, its query reference freed on cleanup).
         (cond ((typep value 'managed-object)
                (let ((number (%query-number-interface (%require-live-pointer value))))
                  (values number
                          (let ((v value))
                            (lambda () v (%release-pointer number))))))
               ((null value)
                (values (cffi:null-pointer) nil))
               (t
                (let ((boxed
                        (cond ((integerp value)
                               (opendaq.low-level:integer/create-integer value))
                              ((realp value)
                               (opendaq.low-level:float-object/create-float
                                (coerce value 'double-float)))
                              (t
                               (error "Cannot coerce ~S to an openDAQ Number." value)))))
                  (let ((number (%query-number-interface boxed)))
                    (%release-pointer boxed)
                    (values number (make-cleanup number)))))))
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

(export '(release raw-pointer))

(defun primitive-type-p (type-name)
  "Return T if TYPE-NAME names a boxed primitive (integer, boolean,
float, number, string, ratio, or complex-number) rather than
a full managed-object class like DEVICE or SIGNAL."
  (member type-name '(boolean-object float-object integer-object number-object
                      ratio-object string-object complex-number-object)))

(defun %boxed-value (object target-type)
  "Extract the native Lisp value from a boxed primitive OBJECT, reading it as
TARGET-TYPE (a primitive class symbol, e.g. INTEGER-OBJECT), without releasing it."
  (let ((ptr (%require-live-pointer object)))
    (ecase target-type
      (boolean-object        (not (zerop (opendaq.low-level:boolean/get-value ptr))))
      (float-object          (opendaq.low-level:float-object/get-value ptr))
      (integer-object        (opendaq.low-level:integer/get-value ptr))
      (number-object         (opendaq.low-level:number/get-float-value ptr))
      (ratio-object          (/ (opendaq.low-level:ratio/get-numerator ptr)
                             (opendaq.low-level:ratio/get-denominator ptr)))
      (string-object  (cffi:foreign-string-to-lisp (opendaq.low-level:string/get-char-ptr ptr)))
      (complex-number-object (complex (opendaq.low-level:complex-number/get-real ptr)
                                      (opendaq.low-level:complex-number/get-imaginary ptr))))))

(defun %unbox-primitive (object target-type)
  "Extract the Lisp value from a boxed primitive wrapper and release the temporary
wrapper.  TARGET-TYPE is a symbol naming the primitive class (e.g. INTEGER-OBJECT)."
  (prog1 (%boxed-value object target-type)
    (release object)))
