(in-package #:opendaq.tests)

(in-suite high-level-device-suite)

(test high-level-address-info-builder
  (let ((builder (make-instance 'daq:address-info-builder)))
    (setf (daq:connection-string builder) "daqref://device0"
          (daq:reachability-status builder) :daq-address-reachability-status-unknown
          (daq:type builder) "Type"
          (daq:address builder) "Address")
    (let ((address-info (daq:build builder)))
      (is (typep address-info 'daq:address-info)
          "High-level address-info builders should build generated address-info wrappers.")
      (is (string= "daqref://device0" (daq:connection-string address-info))
          "High-level address-info builders should preserve the connection string.")
      (is (string= "Type" (daq:address-info-type address-info))
          "High-level address-info builders should preserve the type field.")
      (is (string= "Address" (daq:address-info-address address-info))
          "High-level address-info builders should preserve the address field."))))

(test high-level-device-info
  (let* ((instance (make-instance 'daq:instance))
         (root-device (daq:root-device instance))
         (device-info (daq:info root-device)))
    (is (typep device-info 'daq:device-info)
        "High-level devices should expose generated device-info wrappers.")
    (is (stringp (daq:connection-string device-info))
        "High-level device info should expose its connection string as a Lisp string.")
    (is (> (length (daq:name device-info)) 0)
        "High-level device info should expose a non-empty device name.")))
