(in-package #:opendaq.tests)

(in-suite high-level-suite)

(test high-level-low-level-ratio-namespace
  (let ((ratio (daq:wrap-ratio (daq.ll:ratio/create-ratio 8 12))))
    (unwind-protect
        (progn
          (is (= 8 (daq:numerator ratio))
              "High-level wrapper failed to read numerator from the low-level namespace alias.")
          (is (= 12 (daq:denominator ratio))
              "High-level wrapper failed to read denominator from the low-level namespace alias."))
      (daq:release ratio))))

(test high-level-ratio-make-instance
  (let ((ratio (make-instance 'daq:ratio :numerator 6 :denominator 9)))
    (unwind-protect
        (progn
          (is (= 6 (daq:numerator ratio))
              "High-level numerator mismatch")
          (is (= 9 (daq:denominator ratio))
              "High-level denominator mismatch")
          (is (not (cffi:null-pointer-p (daq:raw-pointer ratio)))
              "High-level ratio should hold a native pointer"))
      (daq:release ratio))))

(test high-level-ratio-simplify
  (let* ((ratio (make-instance 'daq:ratio :numerator 6 :denominator 9))
         (simplified nil))
    (unwind-protect
        (progn
          (setf simplified (daq:simplify ratio))
          (is (typep simplified 'daq:ratio)
              "Simplify should return a wrapped high-level ratio.")
          (is (= 2 (daq:numerator simplified))
              "Simplified numerator mismatch")
          (is (= 3 (daq:denominator simplified))
              "Simplified denominator mismatch"))
      (when simplified
        (daq:release simplified))
      (daq:release ratio))))

(test high-level-ratio-release
  (let ((ratio (make-instance 'daq:ratio :numerator 10 :denominator 15)))
    (is (not (cffi:null-pointer-p (daq:raw-pointer ratio)))
        "High-level ratio should have a live pointer before release.")
    (daq:release ratio)
    (is (cffi:null-pointer-p (daq:raw-pointer ratio))
        "High-level ratio should clear its native pointer on release.")))

(test high-level-ratio-automatic-release
  (let ((released nil)
        (weak-pointer nil))
    (let ((ratio (make-instance 'daq:ratio
                                :numerator 14
                                :denominator 21
                                :release-hook (lambda () (setf released t)))))
      (setf weak-pointer (trivial-garbage:make-weak-pointer ratio)))
    (loop repeat 20
          until released
          do (trivial-garbage:gc :full t)
             (sleep 0.01))
    (is (not (null released))
        "High-level ratio should release its native pointer when the wrapper is garbage-collected.")
    (is (null (trivial-garbage:weak-pointer-value weak-pointer))
        "High-level ratio wrapper should be reclaimable without an explicit release call.")))

(test high-level-instance-make-instance
  (let (instance root-device)
    (unwind-protect
        (progn
          (setf instance (make-instance 'daq:instance))
          (setf root-device (daq:root-device instance))
          (is (typep root-device 'daq:device)
              "High-level instance constructor should produce an instance with a root device.")
          (is (not (cffi:null-pointer-p (daq:raw-pointer instance)))
              "High-level instance should hold a live native pointer."))
      (when root-device
        (daq:release root-device))
      (when instance
        (daq:release instance)))))

(test high-level-simulator-read-samples
  (let (instance device channel signals signal reader samples)
    (unwind-protect
        (progn
          (setf instance (make-instance 'daq:instance))
          (setf device (daq:add-device (daq:root-device instance) "daqref://device0"))
          (setf channel (daq:find-component device "IO/AI/RefCh0"))
          (setf signals (daq:signals-recursive channel))
          (setf signal (daq:item-at signals 0))
          (setf (daq:property-value channel "Frequency") 0.5d0)
          (setf reader (make-instance 'daq:stream-reader :signal signal))
          (sleep 0.05)
          (setf samples (daq:read-samples reader 100))
          (is (typep signals 'daq:object-list)
              "Signal discovery should return a wrapped high-level list.")
          (is (= 100 (length samples))
              "High-level stream reader should return the requested number of samples.")
          (is (every #'numberp samples)
              "High-level stream reader should return numeric samples.")
          (is (some (lambda (sample) (> (abs sample) 1d-9)) samples)
              "High-level stream reader should return non-zero simulator samples."))
      (when reader
        (daq:release reader))
      (when signal
        (daq:release signal))
      (when signals
        (daq:release signals))
      (when channel
        (daq:release channel))
      (when device
        (daq:release device))
      (when instance
        (daq:release instance)))))
