(in-package #:opendaq.tests)

(in-suite high-level-context-suite)

(test high-level-context-construction
  (let* ((sinks (make-instance 'daq:object-list))
         (sink (daq:logger-sink-create-std-err-logger-sink)))
    (daq:push-back sinks sink)
    (let* ((logger (make-instance 'daq:logger :sinks sinks :level :daq-log-level-debug))
           (type-manager (make-instance 'daq:type-manager))
           (options (make-instance 'daq:dict))
           (discovery-servers (make-instance 'daq:dict))
           (context (make-instance 'daq:context
                                   :scheduler nil
                                   :logger logger
                                   :type-manager type-manager
                                   :module-manager nil
                                   :authentication-provider nil
                                   :options options
                                   :discovery-servers discovery-servers)))
      (is (typep (daq:logger context) 'daq:logger)
          "High-level contexts should expose their logger wrapper.")
      (is (typep (daq:type-manager context) 'daq:type-manager)
          "High-level contexts should expose their type manager wrapper.")
      (is (typep (daq:options context) 'daq:dict)
          "High-level contexts should expose their options dictionary wrapper.")
      (is (typep (daq:discovery-servers context) 'daq:dict)
          "High-level contexts should expose their discovery-server dictionary wrapper."))))
