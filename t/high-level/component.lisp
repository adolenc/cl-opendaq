(in-package #:opendaq.tests)

(in-suite high-level-component-suite)

(test high-level-component-hierarchy
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
                                   :discovery-servers discovery-servers))
           (parent (make-instance 'daq:component
                                  :context context
                                  :parent nil
                                  :local-id "parent"
                                  :class-name nil))
           (child (make-instance 'daq:component
                                 :context context
                                 :parent parent
                                 :local-id "child"
                                 :class-name nil)))
      (is (string= "child" (daq:local-id child))
          "High-level components should expose their local identifier.")
      (is (string= "/parent/child" (daq:global-id child))
          "High-level child components should synthesize the expected global identifier."))))
