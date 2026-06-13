(in-package #:opendaq.low-level)

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
