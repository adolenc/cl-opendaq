(in-package #:opendaq.tests)

;; Direct port of the portable subset of bindings/c/tests/copendaq/test_copendaq_signal.cpp.
;; DataPacket, DimensionRule, EventPacket, and Range remain blocked because the current generated
;; bindings do not expose the daqNumber/queryInterface paths safely enough for those tests.

(in-suite opendaq-signal-suite)

(defun %make-signal-value-descriptor ()
  (let ((descriptor nil))
    (daq.ll:with-daq-objects (builder unit-builder unit unit-name unit-symbol unit-quantity name)
      (setf builder (daq.ll:data-descriptor-builder/create-data-descriptor-builder))
      (daq.ll:data-descriptor-builder/set-sample-type
       builder
       daq.ll::+daq-sample-type-int-64+)

      (setf unit-builder (daq.ll:unit-builder/create-unit-builder))
      (setf unit-name (daq.ll:make-daq-string "volts"))
      (daq.ll:unit-builder/set-name unit-builder unit-name)
      (setf unit-symbol (daq.ll:make-daq-string "V"))
      (daq.ll:unit-builder/set-symbol unit-builder unit-symbol)
      (setf unit-quantity (daq.ll:make-daq-string "voltage"))
      (daq.ll:unit-builder/set-quantity unit-builder unit-quantity)
      (daq.ll:unit-builder/set-id unit-builder -1)
      (setf unit (daq.ll:unit-builder/build unit-builder))
      (daq.ll:data-descriptor-builder/set-unit builder unit)

      (setf name (daq.ll:make-daq-string "vals"))
      (daq.ll:data-descriptor-builder/set-name builder name)

      (setf descriptor (daq.ll:data-descriptor-builder/build builder)))
    descriptor))

(test opendaq-allocator
  (daq.ll:with-daq-objects (allocator value-descriptor)
    (setf allocator (daq.ll:allocator/create-malloc-allocator))
    (is (not (cffi:null-pointer-p allocator))
        "opendaq/signal Allocator returned a null object")
    (setf value-descriptor (%make-signal-value-descriptor))
    (cffi:with-foreign-object (address-slot :pointer)
      (daq.ll:allocator/allocate allocator value-descriptor 32 4 address-slot)
      (let ((address (cffi:mem-ref address-slot :pointer)))
        (is (not (cffi:null-pointer-p address))
            "opendaq/signal Allocator returned a null data pointer")
        (daq.ll:allocator/free allocator address)))))

(test opendaq-data-descriptor
  (daq.ll:with-daq-objects (value-descriptor name unit symbol)
    (setf value-descriptor (%make-signal-value-descriptor))
    (setf name (daq.ll:data-descriptor/get-name value-descriptor))
    (is (string= "vals" (%daq-string-value name))
        "opendaq/signal DataDescriptor name mismatch")
    (setf unit (daq.ll:data-descriptor/get-unit value-descriptor))
    (setf symbol (daq.ll:unit/get-symbol unit))
    (is (string= "V" (%daq-string-value symbol))
        "opendaq/signal DataDescriptor unit symbol mismatch")
    (is (= daq.ll::+daq-sample-type-int-64+
           (daq.ll:data-descriptor/get-sample-type value-descriptor))
        "opendaq/signal DataDescriptor sample type mismatch")))

(test opendaq-input-port
  (daq.ll:with-daq-objects (context id input-port-config)
    (setf context (%make-test-context))
    (setf id (daq.ll:make-daq-string "daqInputPort"))
    (setf input-port-config
          (daq.ll:input-port-config/create-input-port
           context
           (cffi:null-pointer)
           id
           0))
    (is (not (cffi:null-pointer-p input-port-config))
        "opendaq/signal InputPortConfig returned a null object")))

(test opendaq-scaling
  (daq.ll:with-daq-objects (builder params scale-str offset-str scale offset scaling scaling-params)
    (setf builder (daq.ll:scaling-builder/create-scaling-builder))
    (daq.ll:scaling-builder/set-input-data-type builder daq.ll::+daq-sample-type-int-16+)
    (daq.ll:scaling-builder/set-output-data-type
     builder
     daq.ll::+daq-sample-type-float-32+)
    (daq.ll:scaling-builder/set-scaling-type builder :daq-scaling-type-linear)

    (setf params (daq.ll:dict/create-dict))
    (setf scale-str (daq.ll:make-daq-string "scale"))
    (setf offset-str (daq.ll:make-daq-string "offset"))
    (setf scale (daq.ll:integer/create-integer 10))
    (setf offset (daq.ll:integer/create-integer 10))
    (daq.ll:dict/set params scale-str scale)
    (daq.ll:dict/set params offset-str offset)
    (daq.ll:scaling-builder/set-parameters builder params)

    (setf scaling (daq.ll:scaling-builder/build builder))
    (is (not (cffi:null-pointer-p scaling))
        "opendaq/signal Scaling returned a null object")
    (is (eq :daq-scaling-type-linear (daq.ll:scaling/get-type scaling))
        "opendaq/signal Scaling type mismatch")
    (is (= daq.ll::+daq-sample-type-int-16+ (daq.ll:scaling/get-input-sample-type scaling))
        "opendaq/signal Scaling input sample type mismatch")
    (is (eq :daq-scaled-sample-type-float-32
            (daq.ll:scaling/get-output-sample-type scaling))
        "opendaq/signal Scaling output sample type mismatch")

    (setf scaling-params (daq.ll:scaling/get-parameters scaling))
    (is (= 1 (daq.ll:base-object/equals scaling-params params))
        "opendaq/signal Scaling parameters mismatch")))

(test opendaq-signal
  (daq.ll:with-daq-objects (context id signal-config)
    (setf context (%make-test-context))
    (setf id (daq.ll:make-daq-string "sig"))
    (setf signal-config
          (daq.ll:signal-config/create-signal
           context
           (cffi:null-pointer)
           id
           (cffi:null-pointer)))
    (is (not (cffi:null-pointer-p signal-config))
        "opendaq/signal SignalConfig returned a null object")))
