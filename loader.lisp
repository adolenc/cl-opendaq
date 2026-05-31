(in-package #:opendaq)

(eval-when (:compile-toplevel :load-toplevel :execute)
  #+sbcl
  (require :sb-posix))

(defparameter +native-directory-env-var+ "OPENDAQ_LISP_NATIVE_DIR")
(defparameter +modules-directory-env-var+ "OPENDAQ_MODULES_PATH")

(defparameter +linux-library-stems+
  '("libdaqcoretypes"
    "libdaqcoreobjects"
    "libopendaq"
    "libcopendaq"))

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

(defun %candidate-native-directories ()
  (remove nil
          (list (%directory-if-exists
                 (asdf:system-relative-pathname "opendaq" "bin/"))
                (%environment-native-directory))))

(defun %shared-library-pattern (stem)
  #+linux
  (format nil "~A*.so" stem)
  #-linux
  (error "Only Linux shared libraries are implemented in this milestone."))

(defun %sort-pathnames (pathnames)
  (sort (copy-list pathnames) #'string< :key #'namestring))

(defun %resolve-library-path (directory stem)
  (let* ((pattern (merge-pathnames (%shared-library-pattern stem) directory))
         (matches (%sort-pathnames (directory pattern))))
    (or (first matches)
        (if (string= stem "libcopendaq")
            (error
             "Could not find ~A in ~A. Build openDAQ with OPENDAQ_GENERATE_C_BINDINGS=ON so the C wrapper library is produced."
             stem
             (namestring directory))
            (error "Could not find ~A in ~A." stem (namestring directory))))))

(defun native-library-directory ()
  (or (first (%candidate-native-directories))
      (error
       "Unable to locate openDAQ native libraries. Checked ~{~A~^, ~}. Set ~A to override the search path."
       (mapcar #'namestring
               (remove nil
                       (list (ignore-errors (asdf:system-relative-pathname "opendaq" "bin/"))
                             (ignore-errors (%environment-native-directory)))))
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
             (mapcar (lambda (stem)
                       (%load-native-library
                        (%resolve-library-path resolved-directory stem)))
                     +linux-library-stems+)
             *loaded-native-directory* resolved-directory
             *autoload-error* nil)))))

(defun %condition-string (condition)
  (when condition
    (with-output-to-string (stream)
      (princ condition stream))))

(defun %healthcheck-candidates ()
  (let* ((system-path (ignore-errors (asdf:system-relative-pathname "opendaq" "bin/")))
        (system-directory (and system-path (%directory-if-exists system-path)))
        (environment-value (uiop:getenv +native-directory-env-var+))
        (environment-directory
          (and environment-value
               (plusp (length environment-value))
               (%directory-if-exists environment-value))))
    (remove nil
           (list
            (when system-path
              (list :source :system-bin
                    :path (namestring (uiop:ensure-directory-pathname system-path))
                    :exists (not (null system-directory))))
            (when (and environment-value (plusp (length environment-value)))
              (list :source :environment
                    :path environment-value
                    :exists (not (null environment-directory))))))))

(defun %healthcheck-library-status (directory)
  (when directory
    (mapcar (lambda (stem)
             (handler-case
                 (list :stem stem
                       :ok t
                       :path (namestring (%resolve-library-path directory stem)))
               (error (condition)
                 (list :stem stem
                       :ok nil
                       :error (%condition-string condition)))))
           +linux-library-stems+)))

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
