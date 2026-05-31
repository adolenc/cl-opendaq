(in-package #:opendaq.tests)

;; Direct port of bindings/c/tests/copendaq/test_copendaq_streaming.cpp.

(in-suite opendaq-streaming-suite)

(test opendaq-streaming-type
  (daq.ll:with-daq-objects (id name description prefix streaming-type)
    (setf id (daq.ll:make-daq-string "streamingType"))
    (setf name (daq.ll:make-daq-string "streamingTypeName"))
    (setf description (daq.ll:make-daq-string "streamingTypeDescription"))
    (setf prefix (daq.ll:make-daq-string "streamingTypePrefix"))
    (setf streaming-type
          (daq.ll:streaming-type/create-streaming-type
           id
           name
           description
           prefix
           (cffi:null-pointer)))
    (is (not (cffi:null-pointer-p streaming-type))
        "opendaq/streaming StreamingType returned a null object")))

(test opendaq-subscription-event-args
  (daq.ll:with-daq-objects (streaming-connection-string subscription-event-args connection-string-out)
    (setf streaming-connection-string (daq.ll:make-daq-string "streamingConnectionString"))
    (setf subscription-event-args
          (daq.ll:subscription-event-args/create-subscription-event-args
           streaming-connection-string
           :daq-subscription-event-type-unsubscribed))
    (is (not (cffi:null-pointer-p subscription-event-args))
        "opendaq/streaming SubscriptionEventArgs returned a null object")
    (is (eq :daq-subscription-event-type-unsubscribed
            (daq.ll:subscription-event-args/get-subscription-event-type
             subscription-event-args))
        "opendaq/streaming subscription event type mismatch")
    (setf connection-string-out
          (daq.ll:subscription-event-args/get-streaming-connection-string subscription-event-args))
    (is (string= "streamingConnectionString" (%daq-string-value connection-string-out))
        "opendaq/streaming connection string mismatch")))
