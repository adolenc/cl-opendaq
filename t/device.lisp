(in-package #:opendaq.tests)

;; Direct port of the portable subset of bindings/c/tests/copendaq/test_copendaq_device.cpp.
;; IoFolderConfig remains blocked until daqBaseObject_borrowInterface is supported.

(in-suite opendaq-device-suite)

(test opendaq-address-info
  (daq:with-daq-objects (builder connection-string type address address-info connection-string-out)
    (setf builder (daq:address-info-builder/create-address-info-builder))
    (setf connection-string (daq:make-daq-string "daqref://device0"))
    (daq:address-info-builder/set-connection-string builder connection-string)
    (daq:address-info-builder/set-reachability-status
     builder
     :daq-address-reachability-status-unknown)
    (setf type (daq:make-daq-string "Type"))
    (daq:address-info-builder/set-type builder type)
    (setf address (daq:make-daq-string "Address"))
    (daq:address-info-builder/set-address builder connection-string)
    (daq:address-info-builder/set-address builder address)
    (setf address-info (daq:address-info-builder/build builder))
    (is (not (cffi:null-pointer-p address-info))
        "opendaq/device AddressInfo returned a null object")
    (setf connection-string-out (daq:address-info/get-connection-string address-info))
    (is (not (cffi:null-pointer-p connection-string-out))
        "opendaq/device AddressInfo connection string returned null")))

(test opendaq-device-info
  (daq:with-daq-objects (instance root-device device-info connection-string name)
    (setf instance (%make-test-instance))
    (setf root-device (daq:instance/get-root-device instance))
    (setf device-info (daq:device/get-info root-device))
    (is (not (cffi:null-pointer-p device-info))
        "opendaq/device DeviceInfo returned a null object")
    (setf connection-string (daq:device-info/get-connection-string device-info))
    (is (not (cffi:null-pointer-p connection-string))
        "opendaq/device DeviceInfo connection string returned null")
    (setf name (daq:device-info/get-name device-info))
    (is (not (cffi:null-pointer-p name))
        "opendaq/device DeviceInfo name returned null")))
