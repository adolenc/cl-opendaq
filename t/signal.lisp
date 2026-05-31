(in-package #:opendaq.tests)

;; Direct port of the portable subset of bindings/c/tests/copendaq/test_copendaq_signal.cpp.
;; DataPacket, DimensionRule, EventPacket, and Range remain blocked because the current generated
;; bindings do not expose the daqNumber/queryInterface paths safely enough for those tests.

(in-suite opendaq-signal-suite)

(defun %make-signal-value-descriptor ()
  (let ((descriptor nil))
    (daq:with-daq-objects (builder unit-builder unit unit-name unit-symbol unit-quantity name)
      (setf builder (daq:data-descriptor-builder/create-data-descriptor-builder))
      (daq:data-descriptor-builder/set-sample-type
       builder
       daq::+daq-sample-type-int-64+)

      (setf unit-builder (daq:unit-builder/create-unit-builder))
      (setf unit-name (daq:make-daq-string "volts"))
      (daq:unit-builder/set-name unit-builder unit-name)
      (setf unit-symbol (daq:make-daq-string "V"))
      (daq:unit-builder/set-symbol unit-builder unit-symbol)
      (setf unit-quantity (daq:make-daq-string "voltage"))
      (daq:unit-builder/set-quantity unit-builder unit-quantity)
      (daq:unit-builder/set-id unit-builder -1)
      (setf unit (daq:unit-builder/build unit-builder))
      (daq:data-descriptor-builder/set-unit builder unit)

      (setf name (daq:make-daq-string "vals"))
      (daq:data-descriptor-builder/set-name builder name)

      (setf descriptor (daq:data-descriptor-builder/build builder)))
    descriptor))

(test opendaq-allocator
  (daq:with-daq-objects (allocator value-descriptor)
    (setf allocator (daq:allocator/create-malloc-allocator))
    (is (not (cffi:null-pointer-p allocator))
        "opendaq/signal Allocator returned a null object")
    (setf value-descriptor (%make-signal-value-descriptor))
    (cffi:with-foreign-object (address-slot :pointer)
      (daq:allocator/allocate allocator value-descriptor 32 4 address-slot)
      (let ((address (cffi:mem-ref address-slot :pointer)))
        (is (not (cffi:null-pointer-p address))
            "opendaq/signal Allocator returned a null data pointer")
        (daq:allocator/free allocator address)))))

(test opendaq-data-descriptor
  (daq:with-daq-objects (value-descriptor name unit symbol)
    (setf value-descriptor (%make-signal-value-descriptor))
    (setf name (daq:data-descriptor/get-name value-descriptor))
    (is (string= "vals" (%daq-string-value name))
        "opendaq/signal DataDescriptor name mismatch")
    (setf unit (daq:data-descriptor/get-unit value-descriptor))
    (setf symbol (daq:unit/get-symbol unit))
    (is (string= "V" (%daq-string-value symbol))
        "opendaq/signal DataDescriptor unit symbol mismatch")
    (is (= daq::+daq-sample-type-int-64+
           (daq:data-descriptor/get-sample-type value-descriptor))
        "opendaq/signal DataDescriptor sample type mismatch")))

(test opendaq-input-port
  (daq:with-daq-objects (context id input-port-config)
    (setf context (%make-test-context))
    (setf id (daq:make-daq-string "daqInputPort"))
    (setf input-port-config
          (daq:input-port-config/create-input-port
           context
           (cffi:null-pointer)
           id
           0))
    (is (not (cffi:null-pointer-p input-port-config))
        "opendaq/signal InputPortConfig returned a null object")))

(test opendaq-scaling
  (daq:with-daq-objects (builder params scale-str offset-str scale offset scaling scaling-params)
    (setf builder (daq:scaling-builder/create-scaling-builder))
    (daq:scaling-builder/set-input-data-type builder daq::+daq-sample-type-int-16+)
    (daq:scaling-builder/set-output-data-type
     builder
     daq::+daq-sample-type-float-32+)
    (daq:scaling-builder/set-scaling-type builder :daq-scaling-type-linear)

    (setf params (daq:dict/create-dict))
    (setf scale-str (daq:make-daq-string "scale"))
    (setf offset-str (daq:make-daq-string "offset"))
    (setf scale (daq:integer/create-integer 10))
    (setf offset (daq:integer/create-integer 10))
    (daq:dict/set params scale-str scale)
    (daq:dict/set params offset-str offset)
    (daq:scaling-builder/set-parameters builder params)

    (setf scaling (daq:scaling-builder/build builder))
    (is (not (cffi:null-pointer-p scaling))
        "opendaq/signal Scaling returned a null object")
    (is (eq :daq-scaling-type-linear (daq:scaling/get-type scaling))
        "opendaq/signal Scaling type mismatch")
    (is (= daq::+daq-sample-type-int-16+ (daq:scaling/get-input-sample-type scaling))
        "opendaq/signal Scaling input sample type mismatch")
    (is (eq :daq-scaled-sample-type-float-32
            (daq:scaling/get-output-sample-type scaling))
        "opendaq/signal Scaling output sample type mismatch")

    (setf scaling-params (daq:scaling/get-parameters scaling))
    (is (= 1 (daq:base-object/equals scaling-params params))
        "opendaq/signal Scaling parameters mismatch")))

(test opendaq-signal
  (daq:with-daq-objects (context id signal-config)
    (setf context (%make-test-context))
    (setf id (daq:make-daq-string "sig"))
    (setf signal-config
          (daq:signal-config/create-signal
           context
           (cffi:null-pointer)
           id
           (cffi:null-pointer)))
    (is (not (cffi:null-pointer-p signal-config))
        "opendaq/signal SignalConfig returned a null object")))
