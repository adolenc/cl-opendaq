(in-package #:opendaq.tests)

(in-suite high-level-smoke-suite)

(test high-level-simulator-reads
  (locally (declare (optimize (debug 3)))
    (let* ((instance (make-instance 'daq:instance))
           (root-device (daq:root-device instance))
           (device (daq:add-device root-device "daqref://device0"))
           (channel (daq:find-component device "IO/AI/RefCh0"))
           (signals (daq:signals-recursive (daq:as channel 'daq:channel))))
      (is (plusp (cl:length signals)) "High-level signal discovery should find at least one signal on the channel.")
      (let ((signal (first signals)))
        ;; No priming read: the first READ must skip the reader's initial
        ;; descriptor-change event on its own and still return samples.
        (let ((reader (make-instance 'daq:stream-reader :signal signal)))
          (let ((samples (daq:read reader 100 :timeout-ms 2000)))
            (is (vectorp samples) "Stream reader READ should return a vector.")
            (is (= 100 (cl:length samples)) "Stream reader READ should return the requested number of samples.")
            (is (every #'numberp samples) "Stream reader READ should return numeric elements.")
            (is (eq 'double-float (array-element-type samples)) "Stream reader default value-type should be double-float.")))
        (let ((reader2 (make-instance 'daq:stream-reader :signal signal)))
          (multiple-value-bind (values domain)
              (daq:read-with-domain reader2 10 :timeout-ms 2000)
            (is (= 10 (cl:length values)) "read-with-domain should return the requested number of values.")
            (is (vectorp domain) "read-with-domain domain should be a vector.")
            (is (= (cl:length values) (cl:length domain)) "read-with-domain value and domain arrays must have equal length.")
            (is (equal '(signed-byte 64) (array-element-type domain)) "read-with-domain domain default type should be signed-byte 64.")
            (let ((timestamps (map 'vector (daq:domain-time-converter signal) domain)))
              (is (= (cl:length domain) (cl:length timestamps)) "domain-time-converter should map each tick to a timestamp.")
              (is (every (lambda (ts) (typep ts 'local-time:timestamp)) timestamps) "domain-time-converter should produce LOCAL-TIME timestamps.")
              (is (apply #'local-time:timestamp<= (coerce timestamps 'list)) "Successive domain ticks should map to non-decreasing timestamps.")
              (is (local-time:timestamp= (aref timestamps 0)
                                         (daq:domain-tick->timestamp signal (aref domain 0)))
                  "domain-tick->timestamp should agree with the domain-time-converter closure."))))))))

(test high-level-component-type-detection
  (let* ((instance (make-instance 'daq:instance))
         (device (daq:add-device (daq:root-device instance) "daqref://device0"))
         (channel (daq:find-component device "IO/AI/RefCh0"))
         (signal (first (daq:signals-recursive (daq:as channel 'daq:channel)))))
    (is (eq 'daq:device (daq:component-type device)) "component-type should identify the reference device as DEVICE.")
    (is (eq 'daq:channel (daq:component-type channel)) "component-type should identify a reference channel as CHANNEL.")
    (is (eq 'daq:signal (daq:component-type signal)) "component-type should identify a channel's signal as SIGNAL.")
    (is (daq:is-p channel 'daq:folder) "A channel should support IFolder (a channel is a function block).")
    (is (not (daq:is-p signal 'daq:folder)) "A signal should not support IFolder (the failure path must not crash).")))

(test high-level-multi-reader
  (locally (declare (optimize (debug 3)))
    (let* ((instance (make-instance 'daq:instance))
           (device (daq:add-device (daq:root-device instance) "daqref://device0"))
           (channels (list (daq:as (daq:find-component device "IO/AI/RefCh0") 'daq:channel)
                           (daq:as (daq:find-component device "IO/AI/RefCh1") 'daq:channel)))
           (signals (mapcar (lambda (channel) (first (daq:signals channel))) channels))
           ;; :SIGNALS accepts a plain Lisp list (built into an object-list for us).
           (reader (make-instance 'daq:multi-reader :signals signals)))
      ;; The first reads only synchronise the streams; loop until aligned data.
      (loop for attempt below 30
            do (multiple-value-bind (values domain)
                   (daq:read-with-domain reader 10 :timeout-ms 1000)
                 (when (plusp (cl:length (first domain)))
                   (is (= 2 (cl:length values)) "Multi reader should return one value vector per signal.")
                   (is (= 2 (cl:length domain)) "Multi reader should return one domain vector per signal.")
                   (is (apply #'= (mapcar #'cl:length values)) "All per-signal value vectors should share the same length.")
                   (is (every (lambda (v) (eq 'double-float (array-element-type v))) values) "Multi reader default value type should be double-float.")
                   (is (equalp (first domain) (second domain)) "Synchronised signals should share identical domain ticks.")
                   (is (= 2 (cl:length (daq:read reader 5 :timeout-ms 1000))) "Multi reader READ should also return one vector per signal.")
                   (return)))
            finally (fail "Multi reader did not synchronise within the attempt budget.")))))

(test high-level-block-reader
  (locally (declare (optimize (debug 3)))
    (let* ((instance (make-instance 'daq:instance))
           (root-device (daq:root-device instance))
           (device (daq:add-device root-device "daqref://device0"))
           (channel (daq:find-component device "IO/AI/RefCh0"))
           (signals (daq:signals-recursive (daq:as channel 'daq:channel)))
           (signal (first signals))
           (reader (make-instance 'daq:block-reader :signal signal :block-size 10)))
      (let ((blocks (daq:read reader 5 :timeout-ms 2000)))
        (is (= 2 (array-rank blocks)) "block reader READ should return a 2-D array.")
        (is (= 5 (array-dimension blocks 0)) "block reader READ should return the requested number of blocks.")
        (is (= 10 (array-dimension blocks 1)) "block reader READ columns should equal the block size.")
        (is (eq 'double-float (array-element-type blocks)) "block reader default value-type should be double-float.")))))

(test high-level-data-packet-buffers
  (let ((builder (make-instance 'daq:data-descriptor-builder)))
    (setf (daq:sample-type builder) :float64)
    (let* ((descriptor (daq:build builder))
           (offset (make-instance 'daq:integer-object :value 0))
           (packet (make-instance 'daq:data-packet
                                  :descriptor descriptor :sample-count 8 :offset offset))
           (values (daq:data packet))
           (raw (daq:raw-data packet)))
      (is (vectorp values) "data-packet DATA should return a vector.")
      (is (= 8 (cl:length values)) "data-packet DATA length should match the sample count.")
      (is (eq 'double-float (array-element-type values)) "data-packet DATA element type should follow the descriptor sample type.")
      (is (equal '(unsigned-byte 8) (array-element-type raw)) "data-packet RAW-DATA should be an (unsigned-byte 8) vector.")
      (is (= 64 (cl:length raw)) "data-packet RAW-DATA size should be sample-count * element-size bytes."))))

(test high-level-data-packet-write
  ;; (SETF DATA) accepts any sequence and coerces each element to the descriptor's
  ;; sample type; DATA reads it back.  Cover a float vector, integer rounding, a
  ;; complex round-trip, and the error raised for a non-numeric-buffer sample type.
  (flet ((make-packet (sample-type count)
           (let ((builder (make-instance 'daq:data-descriptor-builder)))
             (setf (daq:sample-type builder) sample-type)
             (make-instance 'daq:data-packet
                            :descriptor (daq:build builder)
                            :sample-count count
                            :offset (make-instance 'daq:integer-object :value 0)))))
    ;; Float64 written from a VECTOR (not just a list).
    (let ((packet (make-packet :float64 4)))
      (setf (daq:data packet) #(1.5 2.5 3.5 4.5))
      (let ((back (daq:data packet)))
        (is (eq 'double-float (array-element-type back)) "float64 DATA should be a double-float vector.")
        (is (every #'= #(1.5 2.5 3.5 4.5) back) "(SETF DATA) should accept a vector and round-trip float samples.")))
    ;; Int32: reals are rounded into the integer buffer.
    (let ((packet (make-packet :int32 3)))
      (setf (daq:data packet) '(1 2.6 -3.2))
      (is (every #'= #(1 3 -3) (daq:data packet)) "(SETF DATA) should round reals into an integer sample buffer."))
    ;; Complex float64: samples are stored as interleaved (real, imaginary) pairs.
    (let ((packet (make-packet :complexfloat64 2)))
      (setf (daq:data packet) (vector #C(1.0d0 2.0d0) #C(3.0d0 -4.0d0)))
      (is (every #'= #(#C(1.0d0 2.0d0) #C(3.0d0 -4.0d0)) (daq:data packet))
          "(SETF DATA) and DATA should round-trip complex samples."))
    ;; A sample type that is not a flat numeric buffer errors rather than corrupting.
    (signals error (daq:data (make-packet :struct 1)))))

(test high-level-create-signal-and-read
  ;; Build a signal by hand, push packets into it, and read them back with a
  ;; StreamReader.  The domain uses an implicit linear rule, so the rule's
  ;; delta/start and the packets' offsets are passed as plain Lisp integers --
  ;; the :DAQ-NUMBER coercion queries them to INumber, which is what openDAQ's
  ;; DataRule and DataPacket factories require (a raw Integer pointer corrupts
  ;; the later read).
  (let* ((context (daq:context (make-instance 'daq:instance)))
         (domain-descriptor
           (let ((b (make-instance 'daq:data-descriptor-builder)))
             (setf (daq:sample-type b) :int64
                   (daq:name b) "time"
                   (daq:rule b) (make-instance 'daq:data-rule/linear :delta 1 :start 0))
             (daq:build b)))
         (value-descriptor
           (let ((b (make-instance 'daq:data-descriptor-builder)))
             (setf (daq:sample-type b) :float64
                   (daq:name b) "values")
             (daq:build b)))
         (domain-signal (make-instance 'daq:signal-config
                                       :context context :parent nil :local-id "time" :class-name nil))
         (signal (make-instance 'daq:signal-config
                                :context context :parent nil :local-id "values" :class-name nil)))
    (setf (daq:descriptor domain-signal) domain-descriptor
          (daq:descriptor signal) value-descriptor
          (daq:domain-signal signal) domain-signal)
    (let ((reader (make-instance 'daq:stream-reader :signal signal :timeout-type :any)))
      (flet ((send (offset samples)
               (let* ((count (cl:length samples))
                      (domain-packet (make-instance 'daq:data-packet
                                                    :descriptor domain-descriptor
                                                    :sample-count count :offset offset))
                      (packet (make-instance 'daq:data-packet/with-domain
                                             :domain-packet domain-packet
                                             :descriptor value-descriptor
                                             :sample-count count :offset 0)))
                 (setf (daq:data packet) samples)
                 (daq:send-packet signal packet))))
        (send 0 '(1.0 2.0 3.0 4.0))
        (send 4 '(5.0 6.0 7.0 8.0))
        (send 8 '(9.0 10.0)))
      (multiple-value-bind (values ticks) (daq:read-with-domain reader 100 :timeout-ms 1000)
        (is (= 10 (cl:length values)) "Reading a hand-built signal should return every sent sample.")
        (is (equalp #(1.0d0 2.0d0 3.0d0 4.0d0 5.0d0 6.0d0 7.0d0 8.0d0 9.0d0 10.0d0) values)
            "The read values should match the samples written into the packets.")
        (is (equalp #(0 1 2 3 4 5 6 7 8 9) ticks)
            "The implicit linear domain should yield contiguous ticks across packets.")))))

(test high-level-callable-properties
  (let* ((instance (make-instance 'daq:instance))
         (device (daq:add-device (daq:root-device instance) "daqref://device0"))
         (object (daq:as device 'daq:property-object))
         (channel (daq:as (daq:find-component device "IO/AI/RefCh0") 'daq:property-object)))
    ;; FUNC property: PROPERTY-VALUE returns a Lisp function that boxes the
    ;; arguments, invokes the callable, and unboxes the (INT) result.
    (let ((sum (daq:property-value object "Protected.Sum")))
      (is (functionp sum) "PROPERTY-VALUE of a FUNC property should return a Lisp function.")
      (is (= 12 (funcall sum 7 5)) "Calling a FUNC property should box the args, invoke it, and unbox the result.")
      (is (= 42 (funcall sum 40 2)) "The returned function should be reusable across calls.")
      (signals error (funcall sum 1) "Calling a FUNC property with the wrong number of arguments should signal an error."))
    ;; FUNC property taking a LIST argument: a Lisp list is boxed into an
    ;; OBJECT-LIST, and an explicit OBJECT-LIST is passed through unchanged.
    (let ((sum-list (daq:property-value object "Protected.SumList")))
      (is (= 10 (funcall sum-list '(1 2 3 4))) "A LIST argument should accept a plain Lisp list, boxing it into an OBJECT-LIST.")
      (is (= 10 (let ((boxed (make-instance 'daq:object-list)))
                  (dolist (x '(1 2 3 4)) (daq:push-back boxed x))
                  (funcall sum-list boxed)))
          "A LIST argument should also accept an explicit OBJECT-LIST."))
    ;; Scalar property: unaffected by the callable :around -- still a boxed value.
    (let ((number-of-channels (daq:property-value object "NumberOfChannels")))
      (is (not (functionp number-of-channels)) "PROPERTY-VALUE of a scalar property should not be wrapped as a function.")
      (is (integerp (daq:unbox (daq:as number-of-channels 'daq:integer-object))) "A scalar property value should still unbox to its native value."))
    ;; PROC property with no arguments: dispatched for its side effect, yields NIL.
    (let ((reset (daq:property-value channel "ResetCounter")))
      (is (functionp reset) "PROPERTY-VALUE of a PROC property should return a Lisp function.")
      (is (null (funcall reset)) "Calling a PROC property should dispatch it and return NIL.")
      (signals error (funcall reset 1) "A zero-argument PROC property should reject surplus arguments."))
    ;; FUNC property with a single argument: the bare-value param encoding.
    (let ((get-and-set (daq:property-value channel "GetAndSetCounter")))
      (is (integerp (funcall get-and-set 0)) "A single-argument FUNC property should encode its lone arg and unbox the INT result."))))

(test high-level-callable-argument-boxing
  ;; No reference-device property takes a dict argument, so exercise the boxing
  ;; that PROPERTY-VALUE's callable wrapper performs directly: a Lisp hash-table is
  ;; boxed into a DICT according to the argument info's key/item types.  The list
  ;; path is covered end-to-end by Protected.SumList in HIGH-LEVEL-CALLABLE-PROPERTIES.
  (flet ((box (value info) (opendaq.high-level::%box-callable-argument value info)))
    ;; DICT argument: hash-table -> DICT, keys/values boxed per key/item type.
    (let ((table (make-hash-table :test 'equal)))
      (setf (gethash "x" table) 10 (gethash "y" table) 20)
      (let* ((info (make-instance 'daq:argument-info/dict :name "D" :key-type :string :item-type :int))
             (dict (box table info))
             (round-trip (daq:as-hashtable-of dict 'daq:string-object 'daq:integer-object)))
        (is (typep dict 'daq:dict) "A dict argument should box a Lisp hash-table into a DICT.")
        (is (= 2 (hash-table-count round-trip)) "The boxed dict should preserve the entry count.")
        (is (= 10 (gethash "x" round-trip)) "The boxed dict should preserve its string->int entries.")
        (is (= 20 (gethash "y" round-trip)) "The boxed dict should preserve its string->int entries.")))
    ;; openDAQ reports a dict argument's core type as :LIST -- the key type is what
    ;; marks it as a dict, so detection must not rely on the core type alone.
    (is (eq :list (daq:argument-info-type
                   (make-instance 'daq:argument-info/dict :name "D" :key-type :string :item-type :int)))
        "openDAQ reports a dict argument's core type as :LIST.")
    ;; LIST argument: an empty Lisp list boxes to an empty OBJECT-LIST (unambiguous
    ;; because boxing is driven by the declared type, not the value's shape).
    (let* ((info (make-instance 'daq:argument-info/list :name "L" :item-type :int))
           (empty (box nil info)))
      (is (typep empty 'daq:object-list) "An empty list argument should box NIL into an empty OBJECT-LIST.")
      (is (zerop (daq:count empty)) "The boxed empty list should have no elements."))
    ;; An already-wrapped collection passes through unchanged.
    (let ((info (make-instance 'daq:argument-info/list :name "L" :item-type :int))
          (explicit (make-instance 'daq:object-list)))
      (daq:push-back explicit 99)
      (is (eq explicit (box explicit info)) "An explicit OBJECT-LIST argument should pass through unchanged."))))

(test high-level-autoload-healthcheck
  (let* ((status (daq:healthcheck nil))
         (loaded (getf status :status))
         (directory (getf status :resolved-native-directory))
         (autoload-error (getf status :autoload-error)))
    (is (eq :loaded loaded) "High-level smoke coverage should confirm the native library loads.")
    (is (stringp directory) "High-level smoke coverage should expose the discovered native library directory.")
    (is (null autoload-error) "High-level smoke coverage should confirm autoload completed without an error.")))
