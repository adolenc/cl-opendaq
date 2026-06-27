(in-package #:opendaq.tests)

;; Direct port of the portable subset of bindings/c/tests/copendaq/test_copendaq_component.cpp.
;; ComponentPrivate, ComponentStatusContainer, Folder, Removable, Tags, and other borrowInterface
;; paths remain blocked until daqBaseObject_borrowInterface is supported.

(in-suite low-level-component-suite)

(test opendaq-component
  (opendaq.low-level:with-daq-objects (context parent-id child-id component child child-local-id child-global-id)
    (setf context (%make-test-context))
    (setf parent-id (opendaq.low-level:make-daq-string "parent"))
    (setf child-id (opendaq.low-level:make-daq-string "child"))
    (setf component
          (opendaq.low-level:component/create-component
           context
           (cffi:null-pointer)
           parent-id
           (cffi:null-pointer)))
    (setf child
          (opendaq.low-level:component/create-component
           context
           component
           child-id
           (cffi:null-pointer)))
    (setf child-local-id (opendaq.low-level:component/get-local-id child))
    (is (string= "child" (%daq-string-value child-local-id)) "opendaq/component child local id mismatch")
    (setf child-global-id (opendaq.low-level:component/get-global-id child))
    (is (string= "/parent/child" (%daq-string-value child-global-id)) "opendaq/component child global id mismatch")))
