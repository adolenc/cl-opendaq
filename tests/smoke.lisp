(in-package #:opendaq.tests)

(defun %assert-equal (expected actual description)
  (unless (equal expected actual)
    (error "~A: expected ~S but got ~S." description expected actual)))

(defun %assert-true (value description)
  (unless value
    (error "~A" description)))

(defun %release (pointer)
  (when (and pointer (not (cffi:null-pointer-p pointer)))
    (opendaq:base-object/release-ref pointer))
  nil)

(defun %probe-low-level-simulator ()
  (let ((builder nil)
        (module-path nil)
        (instance nil)
        (root-device nil)
        (connection-string nil)
        (device nil)
        (signals nil)
        (signal nil)
        (reader nil))
    (unwind-protect
        (progn
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
            (%assert-true (plusp signal-count) "Simulator device exposes no signals.")
            (setf signal (opendaq:list/get-item-at signals 0))
            (setf reader
                  (opendaq:stream-reader/create-stream-reader
                   signal
                   opendaq::+daq-sample-type-float-64+
                   opendaq::+daq-sample-type-int-64+
                   :daq-read-mode-scaled
                   :daq-read-timeout-type-all))
            (%assert-true (not (cffi:null-pointer-p reader))
                          "Failed to create a low-level stream reader.")
            signal-count))
      (%release reader)
      (%release signal)
      (%release signals)
      (%release device)
      (%release connection-string)
      (%release root-device)
      (%release instance)
      (%release module-path)
      (%release builder))))

(defun run-smoke-tests ()
  (let ((raw-ratio nil)
        (raw-simplified nil))
    (unwind-protect
        (progn
          (setf raw-ratio (opendaq:ratio/create-ratio 3 9))
          (%assert-equal 3 (opendaq:ratio/get-numerator raw-ratio) "Raw numerator mismatch")
          (%assert-equal 9 (opendaq:ratio/get-denominator raw-ratio) "Raw denominator mismatch")

          (setf raw-simplified (opendaq:ratio/simplify raw-ratio))
          (%assert-equal
           1
           (opendaq:ratio/get-numerator raw-simplified)
           "Raw simplified numerator mismatch")
          (%assert-equal
           3
           (opendaq:ratio/get-denominator raw-simplified)
           "Raw simplified denominator mismatch")

          (%assert-true (plusp (%probe-low-level-simulator))
                        "Simulator probe found no signals")
          t)
      (%release raw-simplified)
      (%release raw-ratio))))
