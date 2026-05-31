(in-package #:opendaq.tests)

;; Direct port of bindings/c/tests/copendaq/test_copendaq_server.cpp.

(in-suite opendaq-server-suite)

(test opendaq-server-type
  (daq.ll:with-daq-objects (id name description default-config server-type)
    (setf id (daq.ll:make-daq-string "id"))
    (setf name (daq.ll:make-daq-string "name"))
    (setf description (daq.ll:make-daq-string "description"))
    (setf default-config (daq.ll:property-object/create-property-object))
    (setf server-type
          (daq.ll:server-type/create-server-type id name description default-config))
    (is (not (cffi:null-pointer-p server-type))
        "opendaq/server ServerType returned a null object")))
