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

(defparameter +native-library-base-names+
  '("daqcoretypes"
    "daqcoreobjects"
    "opendaq"
    "copendaq"))

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

(defun %current-platform-os ()
  (let ((value (string-downcase (software-type))))
    (cond
      ((search "linux" value) "linux")
      ((or (search "darwin" value)
           (search "mac" value))
       "darwin")
      ((search "win" value) "windows")
      (t
       (error "Unsupported operating system for openDAQ native libraries: ~A"
              (software-type))))))

(defun %current-platform-architecture ()
  (let ((value (string-downcase (machine-type))))
    (cond
      ((member value '("x86-64" "x86_64" "amd64") :test #'string=) "x64")
      ((member value '("aarch64" "arm64") :test #'string=) "arm64")
      ((or (string= value "x86")
           (search "i386" value)
           (search "i686" value))
       "x86")
      ((search "arm" value) "arm")
      (t value))))

(defun %current-platform-os-aliases ()
  (let ((os (%current-platform-os)))
    (cond
      ((string= os "darwin") '("darwin" "macos"))
      ((string= os "windows") '("windows" "win32"))
      (t (list os)))))

(defun %current-platform-directory-names ()
  (let ((architecture (%current-platform-architecture)))
    (remove-duplicates
     (append (mapcar (lambda (os)
                       (format nil "~A-~A" os architecture))
                     (%current-platform-os-aliases))
             (%current-platform-os-aliases))
     :test #'string=)))

(defun %native-search-paths-for-root (root)
  (let ((directory (uiop:ensure-directory-pathname root)))
    (append (mapcar (lambda (name)
                      (merge-pathnames (format nil "~A/" name) directory))
                    (%current-platform-directory-names))
            (list directory))))

(defun %candidate-native-directories-for-root (root)
  (remove nil
          (mapcar #'%directory-if-exists
                  (%native-search-paths-for-root root))))

(defun %candidate-native-directories ()
  (remove-duplicates
   (mapcan #'%candidate-native-directories-for-root
           (remove nil
                   (list (%environment-native-directory)
                         (%system-native-directory))))
   :test #'equal
   :key #'namestring))

(defun %configured-native-search-paths ()
  (remove-duplicates
   (mapcan #'%native-search-paths-for-root
           (remove nil
                   (list (%environment-native-directory)
                         (%system-native-directory))))
   :test #'equal
   :key #'namestring))

(defun %shared-library-patterns (base-name)
  (let ((os (%current-platform-os)))
    (cond
      ((string= os "linux")
       (list (format nil "lib~A*.so" base-name)))
      ((string= os "darwin")
       (list (format nil "lib~A*.dylib" base-name)
             (format nil "lib~A*.so" base-name)))
      ((string= os "windows")
       (list (format nil "~A*.dll" base-name)
             (format nil "lib~A*.dll" base-name)))
      (t
       (error "Unsupported operating system for openDAQ native libraries: ~A"
              os)))))

(defun %sort-pathnames (pathnames)
  (sort (copy-list pathnames) #'string< :key #'namestring))

(defun %resolve-library-path (directory base-name)
  (let* ((matches
          (%sort-pathnames
           (remove-duplicates
            (mapcan (lambda (pattern)
                      (directory (merge-pathnames pattern directory)))
                    (%shared-library-patterns base-name))
            :test #'equal
            :key #'namestring)))
        (patterns (%shared-library-patterns base-name)))
    (or (first matches)
       (if (string= base-name "copendaq")
           (error
            "Could not find ~A in ~A matching any of ~{~A~^, ~}. Build openDAQ with OPENDAQ_GENERATE_C_BINDINGS=ON so the C wrapper library is produced."
            base-name
            (namestring directory)
            patterns)
           (error
            "Could not find ~A in ~A matching any of ~{~A~^, ~}."
            base-name
            (namestring directory)
            patterns)))))

(defun native-library-directory ()
  (or (first (%candidate-native-directories))
      (error
       "Unable to locate openDAQ native libraries. Checked ~{~A~^, ~}. Set ~A to override the search path."
       (mapcar #'namestring (%configured-native-search-paths))
       +native-directory-env-var+)))

(defun %load-native-library (path)
  (cffi:load-foreign-library path)
  (namestring path))

(defun %configure-modules-directory (directory)
  (unless (uiop:getenv +modules-directory-env-var+)
    #+sbcl
    (sb-posix:setenv +modules-directory-env-var+ (namestring directory) 1)
    #-sbcl
    (error "Automatic module-path configuration is currently implemented for SBCL only.")))

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
       (%configure-modules-directory resolved-directory)
       (setf *loaded-library-paths*
             (mapcar (lambda (base-name)
                       (%load-native-library
                        (%resolve-library-path resolved-directory base-name)))
                     +native-library-base-names+)
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
    (mapcar (lambda (base-name)
             (handler-case
                 (list :stem base-name
                       :ok t
                       :path (namestring (%resolve-library-path directory base-name)))
               (error (condition)
                 (list :stem base-name
                       :ok nil
                       :error (%condition-string condition)))))
           +native-library-base-names+)))

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
                   (getf library :stem)
                   (getf library :path))
           (format stream "  library ~A: ERROR: ~A~%"
                   (getf library :stem)
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

(defconstant +daq-success+ #x00000000)

;; --- Error code constants ---------------------------------------------------
(defconstant +daq-err-nomemory+                    #x80000000)
(defconstant +daq-err-invalid-parameter+           #x80000001)
(defconstant +daq-err-nointerface+                 #x80004002)
(defconstant +daq-err-size-too-small+              #x80000003)
(defconstant +daq-err-conversion-failed+           #x80000004)
(defconstant +daq-err-out-of-range+                #x80000005)
(defconstant +daq-err-not-found+                   #x80000006)
(defconstant +daq-err-already-exists+              #x8000000A)
(defconstant +daq-err-not-assigned+                #x8000000B)
(defconstant +daq-err-call-failed+                 #x8000000C)
(defconstant +daq-err-parse-failed+                #x8000000D)
(defconstant +daq-err-invalid-value+               #x8000000E)
(defconstant +daq-err-resolve-failed+              #x80000010)
(defconstant +daq-err-invalid-type+                #x80000011)
(defconstant +daq-err-access-denied+               #x80000012)
(defconstant +daq-err-not-enabled+                 #x80000013)
(defconstant +daq-err-general-error+               #x80000014)
(defconstant +daq-err-calc-failed+                 #x80000015)
(defconstant +daq-err-not-implemented+             #x80000016)
(defconstant +daq-err-frozen+                      #x80000017)
(defconstant +daq-err-not-serializable+            #x80000018)
(defconstant +daq-err-factory-not-registered+      #x80000020)
(defconstant +daq-err-deserialize-parse-error+     #x80000021)
(defconstant +daq-err-deserialize-unknown-type+    #x80000022)
(defconstant +daq-err-deserialize-no-type+         #x80000023)
(defconstant +daq-err-invalid-property+            #x80000024)
(defconstant +daq-err-duplicate-item+              #x80000025)
(defconstant +daq-err-argument-null+               #x80000026)
(defconstant +daq-err-invalid-operation+           #x80000027)
(defconstant +daq-err-uninitialized+               #x80000028)
(defconstant +daq-err-invalid-state+               #x80000029)
(defconstant +daq-err-validate-failed+             #x80000030)
(defconstant +daq-err-not-updatable+               #x80000031)
(defconstant +daq-err-no-compatible-version+       #x80000032)
(defconstant +daq-err-locked+                      #x80000033)
(defconstant +daq-err-size-too-large+              #x80000034)
(defconstant +daq-err-buffer-full+                 #x80000035)
(defconstant +daq-err-create-failed+               #x80000036)
(defconstant +daq-err-empty-scaling-table+         #x80000037)
(defconstant +daq-err-empty-range+                 #x80000038)
(defconstant +daq-err-discovery-failed+            #x80000039)
(defconstant +daq-err-coerce-failed+               #x80000040)
(defconstant +daq-err-not-supported+               #x80000041)
(defconstant +daq-err-list-not-homogeneous+        #x80000042)
(defconstant +daq-err-not-frozen+                  #x80000043)
(defconstant +daq-err-no-data+                     #x80000050)
(defconstant +daq-err-device-locked+               #x80000052)
(defconstant +daq-err-reserved-type-name+          #x80000053)

(defparameter *known-error-codes*
  `((,+daq-success+                     . "OPENDAQ_SUCCESS")
    (,+daq-err-nomemory+                . "OPENDAQ_ERR_NOMEMORY")
    (,+daq-err-invalid-parameter+       . "OPENDAQ_ERR_INVALIDPARAMETER")
    (,+daq-err-nointerface+             . "OPENDAQ_ERR_NOINTERFACE")
    (,+daq-err-size-too-small+          . "OPENDAQ_ERR_SIZETOOSMALL")
    (,+daq-err-conversion-failed+       . "OPENDAQ_ERR_CONVERSIONFAILED")
    (,+daq-err-out-of-range+            . "OPENDAQ_ERR_OUTOFRANGE")
    (,+daq-err-not-found+               . "OPENDAQ_ERR_NOTFOUND")
    (,+daq-err-already-exists+          . "OPENDAQ_ERR_ALREADYEXISTS")
    (,+daq-err-not-assigned+            . "OPENDAQ_ERR_NOTASSIGNED")
    (,+daq-err-call-failed+             . "OPENDAQ_ERR_CALLFAILED")
    (,+daq-err-parse-failed+            . "OPENDAQ_ERR_PARSEFAILED")
    (,+daq-err-invalid-value+           . "OPENDAQ_ERR_INVALIDVALUE")
    (,+daq-err-resolve-failed+          . "OPENDAQ_ERR_RESOLVEFAILED")
    (,+daq-err-invalid-type+            . "OPENDAQ_ERR_INVALIDTYPE")
    (,+daq-err-access-denied+           . "OPENDAQ_ERR_ACCESSDENIED")
    (,+daq-err-not-enabled+             . "OPENDAQ_ERR_NOTENABLED")
    (,+daq-err-general-error+           . "OPENDAQ_ERR_GENERALERROR")
    (,+daq-err-calc-failed+             . "OPENDAQ_ERR_CALCFAILED")
    (,+daq-err-not-implemented+         . "OPENDAQ_ERR_NOTIMPLEMENTED")
    (,+daq-err-frozen+                  . "OPENDAQ_ERR_FROZEN")
    (,+daq-err-not-serializable+        . "OPENDAQ_ERR_NOT_SERIALIZABLE")
    (,+daq-err-factory-not-registered+  . "OPENDAQ_ERR_FACTORY_NOT_REGISTERED")
    (,+daq-err-deserialize-parse-error+ . "OPENDAQ_ERR_DESERIALIZE_PARSE_ERROR")
    (,+daq-err-deserialize-unknown-type+ . "OPENDAQ_ERR_DESERIALIZE_UNKNOWN_TYPE")
    (,+daq-err-deserialize-no-type+     . "OPENDAQ_ERR_DESERIALIZE_NO_TYPE")
    (,+daq-err-invalid-property+        . "OPENDAQ_ERR_INVALIDPROPERTY")
    (,+daq-err-duplicate-item+          . "OPENDAQ_ERR_DUPLICATEITEM")
    (,+daq-err-argument-null+           . "OPENDAQ_ERR_ARGUMENT_NULL")
    (,+daq-err-invalid-operation+       . "OPENDAQ_ERR_INVALID_OPERATION")
    (,+daq-err-uninitialized+           . "OPENDAQ_ERR_UNINITIALIZED")
    (,+daq-err-invalid-state+           . "OPENDAQ_ERR_INVALIDSTATE")
    (,+daq-err-validate-failed+         . "OPENDAQ_ERR_VALIDATE_FAILED")
    (,+daq-err-not-updatable+           . "OPENDAQ_ERR_NOT_UPDATABLE")
    (,+daq-err-no-compatible-version+   . "OPENDAQ_ERR_NO_COMPATIBLE_VERSION")
    (,+daq-err-locked+                  . "OPENDAQ_ERR_LOCKED")
    (,+daq-err-size-too-large+          . "OPENDAQ_ERR_SIZETOOLARGE")
    (,+daq-err-buffer-full+             . "OPENDAQ_ERR_BUFFERFULL")
    (,+daq-err-create-failed+           . "OPENDAQ_ERR_CREATE_FAILED")
    (,+daq-err-empty-scaling-table+     . "OPENDAQ_ERR_EMPTY_SCALING_TABLE")
    (,+daq-err-empty-range+             . "OPENDAQ_ERR_EMPTY_RANGE")
    (,+daq-err-discovery-failed+        . "OPENDAQ_ERR_DISCOVERY_FAILED")
    (,+daq-err-coerce-failed+           . "OPENDAQ_ERR_COERCE_FAILED")
    (,+daq-err-not-supported+           . "OPENDAQ_ERR_NOT_SUPPORTED")
    (,+daq-err-list-not-homogeneous+    . "OPENDAQ_ERR_LIST_NOT_HOMOGENEOUS")
    (,+daq-err-not-frozen+              . "OPENDAQ_ERR_NOT_FROZEN")
    (,+daq-err-no-data+                 . "OPENDAQ_ERR_NO_DATA")
    (,+daq-err-device-locked+           . "OPENDAQ_ERR_DEVICE_LOCKED")
    (,+daq-err-reserved-type-name+      . "OPENDAQ_ERR_RESERVED_TYPE_NAME")))

;; --- FFI binding for retrieving the descriptive error message ---------------
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

;; --- Condition and checking -------------------------------------------------

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
  (cffi:with-foreign-string (cstring value)
    (string/create-string cstring)))

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
               ((typep value 'cl:ratio)
                (let ((pointer (opendaq.low-level:ratio/create-ratio
                                (cl:numerator value) (cl:denominator value))))
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
