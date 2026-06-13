(in-package #:opendaq.tests)

;; Direct port of the portable subset of bindings/c/tests/copendaq/test_copendaq_signal.cpp.
;; DataPacket, DimensionRule, EventPacket, and Range remain blocked because the current generated
;; bindings do not expose the daqNumber/queryInterface paths safely enough for those tests.

(in-suite low-level-signal-suite)

(defun %make-signal-value-descriptor ()
  (let ((descriptor nil))
    (opendaq.low-level:with-daq-objects (builder unit-builder unit unit-name unit-symbol unit-quantity name)
      (setf builder (opendaq.low-level:data-descriptor-builder/create-data-descriptor-builder))
      (opendaq.low-level:data-descriptor-builder/set-sample-type
       builder
       opendaq.low-level::+daq-sample-type-int-64+)

      (setf unit-builder (opendaq.low-level:unit-builder/create-unit-builder))
      (setf unit-name (opendaq.low-level:make-daq-string "volts"))
      (opendaq.low-level:unit-builder/set-name unit-builder unit-name)
      (setf unit-symbol (opendaq.low-level:make-daq-string "V"))
      (opendaq.low-level:unit-builder/set-symbol unit-builder unit-symbol)
      (setf unit-quantity (opendaq.low-level:make-daq-string "voltage"))
      (opendaq.low-level:unit-builder/set-quantity unit-builder unit-quantity)
      (opendaq.low-level:unit-builder/set-id unit-builder -1)
      (setf unit (opendaq.low-level:unit-builder/build unit-builder))
      (opendaq.low-level:data-descriptor-builder/set-unit builder unit)

      (setf name (opendaq.low-level:make-daq-string "vals"))
      (opendaq.low-level:data-descriptor-builder/set-name builder name)

      (setf descriptor (opendaq.low-level:data-descriptor-builder/build builder)))
    descriptor))

(test opendaq-allocator
  (opendaq.low-level:with-daq-objects (allocator value-descriptor)
    (setf allocator (opendaq.low-level:allocator/create-malloc-allocator))
    (is (not (cffi:null-pointer-p allocator))
        "opendaq/signal Allocator returned a null object")
    (setf value-descriptor (%make-signal-value-descriptor))
    (cffi:with-foreign-object (address-slot :pointer)
      (opendaq.low-level:allocator/allocate allocator value-descriptor 32 4 address-slot)
      (let ((address (cffi:mem-ref address-slot :pointer)))
        (is (not (cffi:null-pointer-p address))
            "opendaq/signal Allocator returned a null data pointer")
        (opendaq.low-level:allocator/free allocator address)))))

(test opendaq-data-descriptor
  (opendaq.low-level:with-daq-objects (value-descriptor name unit symbol)
    (setf value-descriptor (%make-signal-value-descriptor))
    (setf name (opendaq.low-level:data-descriptor/get-name value-descriptor))
    (is (string= "vals" (%daq-string-value name))
        "opendaq/signal DataDescriptor name mismatch")
    (setf unit (opendaq.low-level:data-descriptor/get-unit value-descriptor))
    (setf symbol (opendaq.low-level:unit/get-symbol unit))
    (is (string= "V" (%daq-string-value symbol))
        "opendaq/signal DataDescriptor unit symbol mismatch")
    (is (= opendaq.low-level::+daq-sample-type-int-64+
           (opendaq.low-level:data-descriptor/get-sample-type value-descriptor))
        "opendaq/signal DataDescriptor sample type mismatch")))

(test opendaq-input-port
  (opendaq.low-level:with-daq-objects (context id input-port-config)
    (setf context (%make-test-context))
    (setf id (opendaq.low-level:make-daq-string "daqInputPort"))
    (setf input-port-config
          (opendaq.low-level:input-port-config/create-input-port
           context
           (cffi:null-pointer)
           id
           0))
    (is (not (cffi:null-pointer-p input-port-config))
        "opendaq/signal InputPortConfig returned a null object")))

(test opendaq-scaling
  (opendaq.low-level:with-daq-objects (builder params scale-str offset-str scale offset scaling scaling-params)
    (setf builder (opendaq.low-level:scaling-builder/create-scaling-builder))
    (opendaq.low-level:scaling-builder/set-input-data-type builder opendaq.low-level::+daq-sample-type-int-16+)
    (opendaq.low-level:scaling-builder/set-output-data-type
     builder
     opendaq.low-level::+daq-sample-type-float-32+)
    (opendaq.low-level:scaling-builder/set-scaling-type builder :daq-scaling-type-linear)

    (setf params (opendaq.low-level:dict/create-dict))
    (setf scale-str (opendaq.low-level:make-daq-string "scale"))
    (setf offset-str (opendaq.low-level:make-daq-string "offset"))
    (setf scale (opendaq.low-level:integer/create-integer 10))
    (setf offset (opendaq.low-level:integer/create-integer 10))
    (opendaq.low-level:dict/set params scale-str scale)
    (opendaq.low-level:dict/set params offset-str offset)
    (opendaq.low-level:scaling-builder/set-parameters builder params)

    (setf scaling (opendaq.low-level:scaling-builder/build builder))
    (is (not (cffi:null-pointer-p scaling))
        "opendaq/signal Scaling returned a null object")
    (is (eq :daq-scaling-type-linear (opendaq.low-level:scaling/get-type scaling))
        "opendaq/signal Scaling type mismatch")
    (is (= opendaq.low-level::+daq-sample-type-int-16+ (opendaq.low-level:scaling/get-input-sample-type scaling))
        "opendaq/signal Scaling input sample type mismatch")
    (is (eq :daq-scaled-sample-type-float-32
            (opendaq.low-level:scaling/get-output-sample-type scaling))
        "opendaq/signal Scaling output sample type mismatch")

    (setf scaling-params (opendaq.low-level:scaling/get-parameters scaling))
    (is (= 1 (opendaq.low-level:base-object/equals scaling-params params))
        "opendaq/signal Scaling parameters mismatch")))

(test opendaq-signal
  (opendaq.low-level:with-daq-objects (context id signal-config)
    (setf context (%make-test-context))
    (setf id (opendaq.low-level:make-daq-string "sig"))
    (setf signal-config
          (opendaq.low-level:signal-config/create-signal
           context
           (cffi:null-pointer)
           id
           (cffi:null-pointer)))
    (is (not (cffi:null-pointer-p signal-config))
        "opendaq/signal SignalConfig returned a null object")))
