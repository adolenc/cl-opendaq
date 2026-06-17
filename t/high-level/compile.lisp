(in-package #:opendaq.tests)

(in-suite high-level-compile-suite)

(test high-level-compile-string-object
  (let ((string-object (daq:wrap
                        (opendaq.low-level:make-daq-string "Hello, C bindings!")
                        'daq:daq-string-object)))
    (is (typep string-object 'daq:daq-string-object)
        "High-level compile coverage should construct a generated wrapper class.")
    (is (= 18 (daq:length string-object))
        "High-level string wrappers should expose their generated length accessor.")
    (is (string= "Hello, C bindings!" (%boxed-string-value string-object))
        "High-level string wrappers should round-trip their native contents.")
    (daq:release string-object)
    (is (cffi:null-pointer-p (daq:raw-pointer string-object))
        "Explicit high-level release should clear the native pointer.")))
