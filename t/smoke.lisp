(in-package #:opendaq.tests)

(in-suite smoke-suite)

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

(test simulator-probe
  (is (plusp (%probe-low-level-simulator))
      "Simulator probe found no signals"))
