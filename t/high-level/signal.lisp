(in-package #:opendaq.tests)

(in-suite high-level-signal-suite)

(test high-level-allocator
  (let* ((allocator (daq:create-malloc-allocator))
         (builder (make-instance 'daq:data-descriptor-builder))
         (unit-builder (make-instance 'daq:unit-builder)))
    (setf (daq:sample-type builder) opendaq.low-level::+daq-sample-type-int-64+
          (daq:name builder) "vals"
          (daq:id unit-builder) -1
          (daq:name unit-builder) "volts"
          (daq:symbol unit-builder) "V"
          (daq:quantity unit-builder) "voltage")
    (let ((unit (daq:build unit-builder)))
      (setf (daq:unit builder) unit)
      (let ((descriptor (daq:build builder)))
        (cffi:with-foreign-object (address-slot :pointer)
          (daq:allocate allocator descriptor 32 4 address-slot)
          (let ((address (cffi:mem-ref address-slot :pointer)))
            (is (not (cffi:null-pointer-p address))
                "High-level allocators should allocate native sample buffers.")
            (daq:free allocator address))))))

(test high-level-data-descriptor
  (let* ((builder (make-instance 'daq:data-descriptor-builder))
         (unit-builder (make-instance 'daq:unit-builder)))
    (setf (daq:sample-type builder) opendaq.low-level::+daq-sample-type-int-64+
          (daq:name builder) "vals"
          (daq:id unit-builder) -1
          (daq:name unit-builder) "volts"
          (daq:symbol unit-builder) "V"
          (daq:quantity unit-builder) "voltage")
    (let* ((unit (daq:build unit-builder)))
      (setf (daq:unit builder) unit)
      (let* ((descriptor (daq:build builder)))
        (is (string= "vals" (daq:name descriptor))
            "High-level data-descriptor builders should preserve the descriptor name.")
        (is (string= "V" (daq:symbol (daq:unit descriptor)))
            "High-level data descriptors should expose the generated unit symbol.")
        (is (= opendaq.low-level::+daq-sample-type-int-64+ (daq:sample-type descriptor))
            "High-level data descriptors should preserve the configured sample type.")))))

(test high-level-input-port-config
  (let* ((sinks (make-instance 'daq:object-list))
         (sink (daq:create-std-err-logger-sink)))
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
           (input-port-config (make-instance 'daq:input-port-config
                                             :context context
                                             :parent nil
                                             :local-id "daqInputPort"
                                             :gap-checking nil)))
      (is (typep input-port-config 'daq:input-port-config)
          "High-level input-port-config wrappers should construct generated objects.")
      (is (null (daq:gap-checking-enabled input-port-config))
          "High-level input-port-config wrappers should decode disabled gap checking into NIL."))))

(test high-level-scaling
  (let* ((parameters (make-instance 'daq:dict))
         (builder (make-instance 'daq:scaling-builder)))
    (daq:set parameters "scale" 10)
    (daq:set parameters "offset" 10)
    (setf (daq:input-data-type builder) opendaq.low-level::+daq-sample-type-int-16+
          (daq:output-data-type builder) opendaq.low-level::+daq-sample-type-float-32+
          (daq:scaling-type builder) :daq-scaling-type-linear
          (daq:parameters builder) parameters)
    (let* ((scaling (daq:build builder))
           (scaling-parameters (daq:parameters scaling))
           (scale-value (daq:get scaling-parameters "scale"))
           (offset-value (daq:get scaling-parameters "offset")))
      (is (= opendaq.low-level::+daq-sample-type-int-16+ (daq:input-sample-type scaling))
          "High-level scaling wrappers should preserve the input sample type.")
      (is (eql :daq-scaled-sample-type-float-32 (daq:output-sample-type scaling))
          "High-level scaling wrappers should preserve the output sample type.")
      (is (eql :daq-scaling-type-linear (daq:scaling-type scaling))
          "High-level scaling wrappers should preserve the scaling type.")
      (is (= 10 (%boxed-integer-value scale-value))
          "High-level scaling parameter dictionaries should preserve boxed numeric values.")
      (is (= 10 (%boxed-integer-value offset-value))
          "High-level scaling parameter dictionaries should preserve boxed numeric values."))))

(test high-level-signal-config
  (let* ((sinks (make-instance 'daq:object-list))
         (sink (daq:create-std-err-logger-sink)))
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
           (builder (make-instance 'daq:data-descriptor-builder))
           (unit-builder (make-instance 'daq:unit-builder)))
      (setf (daq:sample-type builder) opendaq.low-level::+daq-sample-type-int-64+
            (daq:name builder) "vals"
            (daq:id unit-builder) -1
            (daq:name unit-builder) "volts"
            (daq:symbol unit-builder) "V"
            (daq:quantity unit-builder) "voltage")
      (let* ((unit (daq:build unit-builder)))
        (setf (daq:unit builder) unit)
        (let* ((descriptor (daq:build builder))
               (signal-config (daq:create-signal-with-descriptor
                               context descriptor nil "sig" nil)))
          (is (typep signal-config 'daq:signal-config)
              "High-level signal helpers should construct generated signal-config wrappers.")
          (is (not (cffi:null-pointer-p (daq:raw-pointer signal-config)))
              "High-level signal-config wrappers should hold a native pointer after construction.")))))))
