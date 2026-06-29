(in-package #:opendaq.tests)

(in-suite high-level-streaming-suite)

(test high-level-streaming-type
  (let* ((default-config (make-instance 'daq:property-object))
         (streaming-type (make-instance 'daq:streaming-type
                                        :id "streamingType"
                                        :name "streamingTypeName"
                                        :description "streamingTypeDescription"
                                        :prefix "streamingTypePrefix"
                                        :default-config default-config)))
    (is (typep streaming-type 'daq:streaming-type) "High-level streaming-type wrappers should construct generated objects.")
    (is (string= "streamingTypePrefix" (daq:connection-string-prefix streaming-type)) "High-level streaming-type wrappers should expose their connection-string prefix.")))

(test high-level-subscription-event-args
  (let ((subscription-event-args
          (make-instance 'daq:subscription-event-args
                         :streaming-connection-string "streamingConnectionString"
                         :type :subscribed)))
    (is (string= "streamingConnectionString"
                 (daq:streaming-connection-string subscription-event-args))
        "High-level subscription-event-args should expose the connection string.")
    (is (eql :subscribed
             (daq:subscription-event-type subscription-event-args))
        "High-level subscription-event-args should preserve the subscription event type.")))
