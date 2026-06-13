(in-package #:opendaq.tests)

(in-suite low-level-smoke-suite)

(defun %temporary-test-directory ()
  (let ((directory
          (merge-pathnames
           (format nil "opendaq-loader-~D-~D/"
                   (get-universal-time)
                   (random 1000000))
           (uiop:temporary-directory))))
    (ensure-directories-exist directory)
    directory))

(defun %call-with-temporary-test-directory (thunk)
  (let ((directory (%temporary-test-directory)))
    (unwind-protect
         (funcall thunk directory)
      (when (probe-file directory)
        (uiop:delete-directory-tree directory :validate t)))))

(defmacro with-temporary-test-directory ((directory) &body body)
  `(%call-with-temporary-test-directory
    (lambda (,directory)
      ,@body)))

(defun %probe-low-level-simulator ()
  (opendaq.low-level:with-daq-objects (builder module-path instance root-device connection-string device signals signal reader)
    (setf builder (opendaq.low-level:instance-builder/create-instance-builder))
    (setf module-path (opendaq.low-level:make-daq-string (namestring (daq:native-library-directory))))
    (opendaq.low-level:instance-builder/set-module-path builder module-path)
    (opendaq.low-level:instance-builder/enable-standard-providers builder 1)
    (setf instance (opendaq.low-level:instance-builder/build builder))
    (setf root-device (opendaq.low-level:instance/get-root-device instance))
    (cffi:with-foreign-string (uri "daqref://device0")
      (setf connection-string (opendaq.low-level:string/create-string uri)))
    (setf device
          (opendaq.low-level:device/add-device root-device
                                 connection-string
                                 (cffi:null-pointer)))

    (setf signals (opendaq.low-level:device/get-signals-recursive device (cffi:null-pointer)))
    (let ((signal-count (opendaq.low-level:list/get-count signals)))
      (is (plusp signal-count)
          "Simulator device exposes no signals.")
      (setf signal (opendaq.low-level:list/get-item-at signals 0))
      (setf reader
            (opendaq.low-level:stream-reader/create-stream-reader
             signal
             opendaq.low-level::+daq-sample-type-float-64+
             opendaq.low-level::+daq-sample-type-int-64+
             :daq-read-mode-scaled
             :daq-read-timeout-type-all))
      (is (not (cffi:null-pointer-p reader))
          "Failed to create a low-level stream reader.")
      signal-count)))

(test generated-ratio-api
  (opendaq.low-level:with-daq-objects (raw-ratio raw-simplified)
    (setf raw-ratio (opendaq.low-level:ratio/create-ratio 3 9))
    (is (= 3 (opendaq.low-level:ratio/get-numerator raw-ratio))
        "Raw numerator mismatch")
    (is (= 9 (opendaq.low-level:ratio/get-denominator raw-ratio))
        "Raw denominator mismatch")

    (setf raw-simplified (opendaq.low-level:ratio/simplify raw-ratio))
    (is (= 1 (opendaq.low-level:ratio/get-numerator raw-simplified))
        "Raw simplified numerator mismatch")
    (is (= 3 (opendaq.low-level:ratio/get-denominator raw-simplified))
        "Raw simplified denominator mismatch")))

(test autoload-healthcheck
  (let ((report (daq:healthcheck nil)))
    (is (eq :loaded (getf report :status))
        "Library should autoload during system load.")
    (is (not (null (getf report :loaded-native-directory)))
        "Healthcheck did not report a loaded native directory.")))

(test native-directory-prefers-platform-subdirectory
  (with-temporary-test-directory (root)
    (let* ((platform-directory-name
             (first (opendaq.low-level::%current-platform-directory-names)))
           (platform-directory
             (merge-pathnames (format nil "~A/" platform-directory-name) root))
           (candidates nil))
      (ensure-directories-exist platform-directory)
      (setf candidates (opendaq.low-level::%candidate-native-directories-for-root root))
      (is (string= (namestring platform-directory)
                   (namestring (first candidates)))
          "Platform-specific directories should be preferred over the bin root.")
      (is (member (namestring root)
                  (mapcar #'namestring candidates)
                  :test #'string=)
          "The bin root should still remain as a fallback candidate."))))

(test native-directory-honors-environment-override
  (with-temporary-test-directory (root)
    (let* ((platform-directory-name
             (first (opendaq.low-level::%current-platform-directory-names)))
           (platform-directory
             (merge-pathnames (format nil "~A/" platform-directory-name) root))
           (previous (uiop:getenv opendaq.low-level::+native-directory-env-var+)))
      (ensure-directories-exist platform-directory)
      (unwind-protect
           (progn
             #+sbcl
             (sb-posix:setenv opendaq.low-level::+native-directory-env-var+ (namestring root) 1)
             #-sbcl
             (error "These tests expect SBCL for environment overrides.")
             (is (string= (namestring platform-directory)
                          (namestring (daq:native-library-directory)))
                 "The OPENDAQ_LISP_NATIVE_DIR override should take precedence over the bundled bin directory."))
        #+sbcl
        (if previous
            (sb-posix:setenv opendaq.low-level::+native-directory-env-var+ previous 1)
            (sb-posix:unsetenv opendaq.low-level::+native-directory-env-var+))))))

(test simulator-probe
  (is (plusp (%probe-low-level-simulator))
      "Simulator probe found no signals"))
