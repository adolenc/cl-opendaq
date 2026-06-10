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
  (daq.ll:with-daq-objects (builder module-path instance root-device connection-string device signals signal reader)
    (setf builder (daq.ll:instance-builder/create-instance-builder))
    (setf module-path (daq.ll:make-daq-string (namestring (daq:native-library-directory))))
    (daq.ll:instance-builder/set-module-path builder module-path)
    (daq.ll:instance-builder/enable-standard-providers builder 1)
    (setf instance (daq.ll:instance-builder/build builder))
    (setf root-device (daq.ll:instance/get-root-device instance))
    (cffi:with-foreign-string (uri "daqref://device0")
      (setf connection-string (daq.ll:string/create-string uri)))
    (setf device
          (daq.ll:device/add-device root-device
                                 connection-string
                                 (cffi:null-pointer)))

    (setf signals (daq.ll:device/get-signals-recursive device (cffi:null-pointer)))
    (let ((signal-count (daq.ll:list/get-count signals)))
      (is (plusp signal-count)
          "Simulator device exposes no signals.")
      (setf signal (daq.ll:list/get-item-at signals 0))
      (setf reader
            (daq.ll:stream-reader/create-stream-reader
             signal
             daq.ll::+daq-sample-type-float-64+
             daq.ll::+daq-sample-type-int-64+
             :daq-read-mode-scaled
             :daq-read-timeout-type-all))
      (is (not (cffi:null-pointer-p reader))
          "Failed to create a low-level stream reader.")
      signal-count)))

(test generated-ratio-api
  (daq.ll:with-daq-objects (raw-ratio raw-simplified)
    (setf raw-ratio (daq.ll:ratio/create-ratio 3 9))
    (is (= 3 (daq.ll:ratio/get-numerator raw-ratio))
        "Raw numerator mismatch")
    (is (= 9 (daq.ll:ratio/get-denominator raw-ratio))
        "Raw denominator mismatch")

    (setf raw-simplified (daq.ll:ratio/simplify raw-ratio))
    (is (= 1 (daq.ll:ratio/get-numerator raw-simplified))
        "Raw simplified numerator mismatch")
    (is (= 3 (daq.ll:ratio/get-denominator raw-simplified))
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
             (first (opendaq::%current-platform-directory-names)))
           (platform-directory
             (merge-pathnames (format nil "~A/" platform-directory-name) root))
           (candidates nil))
      (ensure-directories-exist platform-directory)
      (setf candidates (opendaq::%candidate-native-directories-for-root root))
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
             (first (opendaq::%current-platform-directory-names)))
           (platform-directory
             (merge-pathnames (format nil "~A/" platform-directory-name) root))
           (previous (uiop:getenv opendaq::+native-directory-env-var+)))
      (ensure-directories-exist platform-directory)
      (unwind-protect
           (progn
             #+sbcl
             (sb-posix:setenv opendaq::+native-directory-env-var+ (namestring root) 1)
             #-sbcl
             (error "These tests expect SBCL for environment overrides.")
             (is (string= (namestring platform-directory)
                          (namestring (daq:native-library-directory)))
                 "The OPENDAQ_LISP_NATIVE_DIR override should take precedence over the bundled bin directory."))
        #+sbcl
        (if previous
            (sb-posix:setenv opendaq::+native-directory-env-var+ previous 1)
            (sb-posix:unsetenv opendaq::+native-directory-env-var+))))))

(test simulator-probe
  (is (plusp (%probe-low-level-simulator))
      "Simulator probe found no signals"))
