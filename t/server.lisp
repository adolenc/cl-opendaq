(in-package #:opendaq.tests)

;; Direct port of bindings/c/tests/copendaq/test_copendaq_server.cpp.

(in-suite opendaq-server-suite)

(test opendaq-server-type
  (daq:with-daq-objects (id name description default-config server-type)
    (setf id (daq:make-daq-string "id"))
    (setf name (daq:make-daq-string "name"))
    (setf description (daq:make-daq-string "description"))
    (setf default-config (daq:property-object/create-property-object))
    (setf server-type
          (daq:server-type/create-server-type id name description default-config))
    (is (not (cffi:null-pointer-p server-type))
        "opendaq/server ServerType returned a null object")))
