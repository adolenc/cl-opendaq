(in-package #:opendaq.tests)

(in-suite high-level-smoke-suite)

(test high-level-simulator-read-samples
  ;; SBCL at default debug levels (debug < 3) may determine that LET*
  ;; bindings holding managed-object wrappers are dead after their raw
  ;; pointer (SAP) is extracted for a CFFI call.  The local OPTIMIZE
  ;; declaration preserves the bindings so that GC does not release the
  ;; underlying C++ objects while we still need them.
  (locally (declare (optimize (debug 3)))
    (let* ((instance (make-instance 'daq:instance))
           (root-device (daq:root-device instance))
           (device (daq:add-device root-device "daqref://device0"))
           (channel (daq:find-component device "IO/AI/RefCh0"))
           (signals (daq:signals-recursive (daq:as channel 'daq:channel))))
      (is (listp signals)
          "High-level signal discovery should return a list of typed signal objects.")
      (is (plusp (cl:length signals))
          "High-level signal discovery should find at least one signal on the channel.")
      (let ((signal (first signals)))
        (setf (daq:property-value channel "Frequency") 0.5d0)
        (let* ((reader (make-instance 'daq:stream-reader :signal signal)))
          (sleep 0.1)
          (let ((samples (daq:read-samples reader 100)))
            (is (= 100 (cl:length samples))
                "High-level stream readers should return the requested number of samples.")
            (is (every #'numberp samples)
                "High-level stream readers should return numeric samples.")
            (is (some (lambda (sample) (> (abs sample) 1d-9)) samples)
                "High-level stream readers should surface non-zero simulator samples.")))))))

(test high-level-autoload-healthcheck
  (let* ((status (daq:healthcheck nil))
         (loaded (getf status :status))
         (directory (getf status :resolved-native-directory))
         (autoload-error (getf status :autoload-error)))
    (is (eq :loaded loaded)
        "High-level smoke coverage should confirm the native library loads.")
    (is (stringp directory)
        "High-level smoke coverage should expose the discovered native library directory.")
    (is (null autoload-error)
        "High-level smoke coverage should confirm autoload completed without an error.")))
