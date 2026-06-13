(in-package #:opendaq.tests)

;; Direct port of bindings/c/tests/copendaq/test_copendaq_server.cpp.

(in-suite low-level-server-suite)

(test opendaq-server-type
  (opendaq.low-level:with-daq-objects (id name description default-config server-type)
    (setf id (opendaq.low-level:make-daq-string "id"))
    (setf name (opendaq.low-level:make-daq-string "name"))
    (setf description (opendaq.low-level:make-daq-string "description"))
    (setf default-config (opendaq.low-level:property-object/create-property-object))
    (setf server-type
          (opendaq.low-level:server-type/create-server-type id name description default-config))
    (is (not (cffi:null-pointer-p server-type))
        "opendaq/server ServerType returned a null object")))
