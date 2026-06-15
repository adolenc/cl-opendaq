(in-package #:opendaq.tests)

(in-suite high-level-opendaq-api-suite)

(test high-level-opendaq-config-provider
  (let ((config-provider (daq:create-env-config-provider)))
    (is (typep config-provider 'daq:config-provider)
        "High-level config-provider helpers should return a generated wrapper.")
    (is (not (cffi:null-pointer-p (daq:raw-pointer config-provider)))
        "High-level config-provider helpers should return a live native pointer.")))

(test high-level-opendaq-instance-builder
  (let* ((builder (make-instance 'daq:instance-builder)))
    (setf (daq:module-path builder) (daq:native-library-directory))
    (daq:enable-standard-providers builder t)
    (let* ((instance (daq:build builder))
           (root-device (daq:root-device instance)))
      (is (stringp (daq:module-path builder))
          "High-level instance builders should preserve their module-path as a Lisp string.")
      (is (typep instance 'daq:instance)
          "High-level instance builders should build generated instance wrappers.")
      (is (typep root-device 'daq:device)
          "High-level instances built through the generated builder should expose a root device."))))

(test high-level-opendaq-instance-make-instance
  (let* ((instance (make-instance 'daq:instance))
         (root-device (daq:root-device instance)))
    (is (typep root-device 'daq:device)
        "High-level instance construction should expose a root device.")
    (is (not (cffi:null-pointer-p (daq:raw-pointer instance)))
        "High-level instances should hold a live native pointer after construction.")))
