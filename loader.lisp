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
             *loaded-native-directory* resolved-directory)))))
