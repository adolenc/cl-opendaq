(in-package #:opendaq.tests)

(in-suite high-level-server-suite)

(test high-level-server-type
  (let* ((default-config (make-instance 'daq:property-object))
         (server-type (make-instance 'daq:server-type
                                     :id "serverType"
                                     :name "serverTypeName"
                                     :description "serverTypeDescription"
                                     :default-config default-config)))
    (is (typep server-type 'daq:server-type)
        "High-level server-type wrappers should construct generated server-type objects.")
    (is (not (cffi:null-pointer-p (daq:raw-pointer server-type)))
        "High-level server-type wrappers should hold a native pointer after construction.")))
