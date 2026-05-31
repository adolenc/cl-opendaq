(in-package #:opendaq.tests)

(in-suite smoke-suite)

(defun %probe-low-level-simulator ()
  (with-daq-objects (builder module-path instance root-device connection-string device signals signal reader)
    (setf builder (opendaq:instance-builder/create-instance-builder))
    (cffi:with-foreign-string (path (namestring (opendaq:native-library-directory)))
      (setf module-path (opendaq:string/create-string path)))
    (opendaq:instance-builder/set-module-path builder module-path)
    (opendaq:instance-builder/enable-standard-providers builder 1)
    (setf instance (opendaq:instance-builder/build builder))

    (setf root-device (opendaq:instance/get-root-device instance))
    (cffi:with-foreign-string (uri "daqref://device0")
      (setf connection-string (opendaq:string/create-string uri)))
    (setf device
          (opendaq:device/add-device root-device
                                     connection-string
                                     (cffi:null-pointer)))

    (setf signals (opendaq:device/get-signals-recursive device (cffi:null-pointer)))
    (let ((signal-count (opendaq:list/get-count signals)))
      (is (plusp signal-count)
          "Simulator device exposes no signals.")
      (setf signal (opendaq:list/get-item-at signals 0))
      (setf reader
            (opendaq:stream-reader/create-stream-reader
             signal
             opendaq::+daq-sample-type-float-64+
             opendaq::+daq-sample-type-int-64+
             :daq-read-mode-scaled
             :daq-read-timeout-type-all))
      (is (not (cffi:null-pointer-p reader))
          "Failed to create a low-level stream reader.")
      signal-count)))

(test generated-ratio-api
  (with-daq-objects (raw-ratio raw-simplified)
    (setf raw-ratio (opendaq:ratio/create-ratio 3 9))
    (is (= 3 (opendaq:ratio/get-numerator raw-ratio))
        "Raw numerator mismatch")
    (is (= 9 (opendaq:ratio/get-denominator raw-ratio))
        "Raw denominator mismatch")

    (setf raw-simplified (opendaq:ratio/simplify raw-ratio))
    (is (= 1 (opendaq:ratio/get-numerator raw-simplified))
        "Raw simplified numerator mismatch")
    (is (= 3 (opendaq:ratio/get-denominator raw-simplified))
        "Raw simplified denominator mismatch")))

(test simulator-probe
  (is (plusp (%probe-low-level-simulator))
      "Simulator probe found no signals"))
