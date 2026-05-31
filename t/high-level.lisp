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
