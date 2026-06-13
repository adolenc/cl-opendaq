(in-package #:opendaq.tests)

;; Direct port of bindings/c/tests/copendaq/test_copendaq_streaming.cpp.

(in-suite low-level-streaming-suite)

(test opendaq-streaming-type
  (opendaq.low-level:with-daq-objects (id name description prefix streaming-type)
    (setf id (opendaq.low-level:make-daq-string "streamingType"))
    (setf name (opendaq.low-level:make-daq-string "streamingTypeName"))
    (setf description (opendaq.low-level:make-daq-string "streamingTypeDescription"))
    (setf prefix (opendaq.low-level:make-daq-string "streamingTypePrefix"))
    (setf streaming-type
          (opendaq.low-level:streaming-type/create-streaming-type
           id
           name
           description
           prefix
           (cffi:null-pointer)))
    (is (not (cffi:null-pointer-p streaming-type))
        "opendaq/streaming StreamingType returned a null object")))

(test opendaq-subscription-event-args
  (opendaq.low-level:with-daq-objects (streaming-connection-string subscription-event-args connection-string-out)
    (setf streaming-connection-string (opendaq.low-level:make-daq-string "streamingConnectionString"))
    (setf subscription-event-args
          (opendaq.low-level:subscription-event-args/create-subscription-event-args
           streaming-connection-string
           :daq-subscription-event-type-unsubscribed))
    (is (not (cffi:null-pointer-p subscription-event-args))
        "opendaq/streaming SubscriptionEventArgs returned a null object")
    (is (eq :daq-subscription-event-type-unsubscribed
            (opendaq.low-level:subscription-event-args/get-subscription-event-type
             subscription-event-args))
        "opendaq/streaming subscription event type mismatch")
    (setf connection-string-out
          (opendaq.low-level:subscription-event-args/get-streaming-connection-string subscription-event-args))
    (is (string= "streamingConnectionString" (%daq-string-value connection-string-out))
        "opendaq/streaming connection string mismatch")))
