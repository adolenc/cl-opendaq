;;; Hand-written high-level layer, loaded after generated/high-level-bindings.lisp.
;;;
;;; The generated bindings are a mechanical 1:1 mapping of the C API.  This file
;;; holds the hand-written pieces that build on top of them:
;;;
;;;   * sample-buffer helpers  — convert openDAQ's untyped (void*) buffers, whose
;;;                              element type is only known at runtime, into typed
;;;                              Lisp vectors
;;;   * reader convenience API — READ / READ-WITH-DOMAIN / READ-SAMPLES
;;;   * data packet accessors  — DATA / RAW-DATA (excluded from generation; see
;;;                              MANUAL_METHODS in the generator)
;;;   * object helpers         — AS / AS-LIST
;;;
;;; Code that must load *before* the generated bindings lives in runtime.lisp
;;; (its high-level runtime section).

(in-package #:opendaq.high-level)

;;; ---------------------------------------------------------------------------
;;; Sample-buffer helpers
;;;
;;; openDAQ exposes sample data through untyped (void*) buffers whose element
;;; type is only known at runtime (from a reader's value/domain read type, or a
;;; data packet's descriptor).  These are the common primitives used by both the
;;; reader API and the data packet accessors below.
;;; ---------------------------------------------------------------------------

(defun %sample-array-type (sample-type)
  "Map an openDAQ sample-type constant to (VALUES cffi-type lisp-element-type)."
  (cond
    ((= sample-type opendaq.low-level::+daq-sample-type-float-64+) (cl:values :double 'double-float))
    ((= sample-type opendaq.low-level::+daq-sample-type-float-32+) (cl:values :float 'single-float))
    ((= sample-type opendaq.low-level::+daq-sample-type-int-8+)    (cl:values :int8 '(signed-byte 8)))
    ((= sample-type opendaq.low-level::+daq-sample-type-u-int-8+)  (cl:values :uint8 '(unsigned-byte 8)))
    ((= sample-type opendaq.low-level::+daq-sample-type-int-16+)   (cl:values :int16 '(signed-byte 16)))
    ((= sample-type opendaq.low-level::+daq-sample-type-u-int-16+) (cl:values :uint16 '(unsigned-byte 16)))
    ((= sample-type opendaq.low-level::+daq-sample-type-int-32+)   (cl:values :int32 '(signed-byte 32)))
    ((= sample-type opendaq.low-level::+daq-sample-type-u-int-32+) (cl:values :uint32 '(unsigned-byte 32)))
    ((= sample-type opendaq.low-level::+daq-sample-type-int-64+)   (cl:values :int64 '(signed-byte 64)))
    ((= sample-type opendaq.low-level::+daq-sample-type-u-int-64+) (cl:values :uint64 '(unsigned-byte 64)))
    (t (cl:values :double 'double-float))))

(defun %buffer->vector (buffer cffi-type element-type count)
  "Copy COUNT elements out of a foreign BUFFER into a fresh typed Lisp vector."
  (let ((result (make-array count :element-type element-type)))
    (dotimes (index count result)
      (setf (aref result index) (cffi:mem-aref buffer cffi-type index)))))

(defun %buffer->matrix (buffer cffi-type element-type rows columns)
  "Copy ROWS*COLUMNS elements out of a flat row-major foreign BUFFER into a fresh
typed 2-D Lisp array of shape (ROWS COLUMNS).  Used for block readers, where each
of the ROWS blocks holds COLUMNS (= block size) samples."
  (let ((result (make-array (cl:list rows columns) :element-type element-type)))
    (dotimes (row rows result)
      (dotimes (column columns)
        (setf (aref result row column)
              (cffi:mem-aref buffer cffi-type (+ (* row columns) column)))))))

;;; ---------------------------------------------------------------------------
;;; Reader convenience API
;;;
;;; STREAM-READER, TAIL-READER and BLOCK-READER are constructed by hand (the
;;; generated constructors are suppressed via MANUAL_CONSTRUCTORS).  The direct C
;;; create call has no skip-events flag, so we build them through their builders
;;; and default :SKIP-EVENTS to T -- matching openDAQ's other bindings.  With it
;;; set, the native reader transparently skips the descriptor-change event it
;;; would otherwise surface before the first samples, so the first READ already
;;; returns data.
;;;
;;; READ / READ-WITH-DOMAIN then allocate a typed buffer, perform a single raw
;;; read, and return the samples as freshly-allocated Lisp arrays: a vector for
;;; stream/tail readers, and a 2-D (blocks x block-size) array for block readers.
;;; The status object is a managed wrapper that releases itself, so nothing here
;;; tracks foreign lifetimes.
;;; ---------------------------------------------------------------------------

(defun %adopt-built-reader (object signal create-builder set-up build)
  "Construct a reader through its builder.  Coerces SIGNAL (pinning it against GC
for the duration), creates a builder with CREATE-BUILDER, configures it via SET-UP
(called with the builder and the signal pointer), BUILDs the reader, releases the
builder, and adopts the resulting reader pointer into OBJECT."
  (multiple-value-bind (signal-pointer cleanup)
      (%coerce-argument signal :managed-pointer)
    (unwind-protect
        (let ((builder (funcall create-builder)))
          (unwind-protect
              (progn
                (funcall set-up builder signal-pointer)
                (%adopt-pointer object (funcall build builder)))
            (%release-pointer builder)))
      (%cleanup-coerced-argument cleanup))))

(defmethod initialize-instance :after
    ((object stream-reader)
     &key (pointer nil pointer-p) (signal nil signal-p)
          (value-read-type opendaq.low-level::+daq-sample-type-float-64+)
          (domain-read-type opendaq.low-level::+daq-sample-type-int-64+)
          (mode :daq-read-mode-scaled)
          (timeout-type :daq-read-timeout-type-all)
          (skip-events t)
     &allow-other-keys)
  (declare (ignore pointer))
  (when (and (not pointer-p) signal-p)
    (%adopt-built-reader
     object signal
     #'opendaq.low-level:stream-reader-builder/create-stream-reader-builder
     (lambda (builder signal-pointer)
       (opendaq.low-level:stream-reader-builder/set-signal builder signal-pointer)
       (opendaq.low-level:stream-reader-builder/set-value-read-type builder value-read-type)
       (opendaq.low-level:stream-reader-builder/set-domain-read-type builder domain-read-type)
       (opendaq.low-level:stream-reader-builder/set-read-mode builder mode)
       (opendaq.low-level:stream-reader-builder/set-read-timeout-type builder timeout-type)
       (opendaq.low-level:stream-reader-builder/set-skip-events builder (if skip-events 1 0)))
     #'opendaq.low-level:stream-reader-builder/build)))

(defmethod initialize-instance :after
    ((object tail-reader)
     &key (pointer nil pointer-p) (signal nil signal-p)
          (history-size nil history-size-p)
          (value-read-type opendaq.low-level::+daq-sample-type-float-64+)
          (domain-read-type opendaq.low-level::+daq-sample-type-int-64+)
          (mode :daq-read-mode-scaled)
          (skip-events t)
     &allow-other-keys)
  (declare (ignore pointer))
  (when (and (not pointer-p) signal-p history-size-p)
    (%adopt-built-reader
     object signal
     #'opendaq.low-level:tail-reader-builder/create-tail-reader-builder
     (lambda (builder signal-pointer)
       (opendaq.low-level:tail-reader-builder/set-signal builder signal-pointer)
       (opendaq.low-level:tail-reader-builder/set-history-size builder history-size)
       (opendaq.low-level:tail-reader-builder/set-value-read-type builder value-read-type)
       (opendaq.low-level:tail-reader-builder/set-domain-read-type builder domain-read-type)
       (opendaq.low-level:tail-reader-builder/set-read-mode builder mode)
       (opendaq.low-level:tail-reader-builder/set-skip-events builder (if skip-events 1 0)))
     #'opendaq.low-level:tail-reader-builder/build)))

(defmethod initialize-instance :after
    ((object block-reader)
     &key (pointer nil pointer-p) (signal nil signal-p)
          (block-size nil block-size-p)
          (value-read-type opendaq.low-level::+daq-sample-type-float-64+)
          (domain-read-type opendaq.low-level::+daq-sample-type-int-64+)
          (mode :daq-read-mode-scaled)
          (skip-events t)
     &allow-other-keys)
  (declare (ignore pointer))
  (when (and (not pointer-p) signal-p block-size-p)
    (%adopt-built-reader
     object signal
     #'opendaq.low-level:block-reader-builder/create-block-reader-builder
     (lambda (builder signal-pointer)
       (opendaq.low-level:block-reader-builder/set-signal builder signal-pointer)
       (opendaq.low-level:block-reader-builder/set-block-size builder block-size)
       (opendaq.low-level:block-reader-builder/set-value-read-type builder value-read-type)
       (opendaq.low-level:block-reader-builder/set-domain-read-type builder domain-read-type)
       (opendaq.low-level:block-reader-builder/set-read-mode builder mode)
       (opendaq.low-level:block-reader-builder/set-skip-events builder (if skip-events 1 0)))
     #'opendaq.low-level:block-reader-builder/build)))

(defgeneric read (reader count &key timeout-ms)
  (:documentation
   "Read up to COUNT samples (or COUNT blocks, for a block reader) from READER.
Returns a Lisp array whose element type matches the reader's VALUE-READ-TYPE: a
vector for stream/tail readers, or a 2-D (blocks x block-size) array for block
readers."))

(defmethod read ((reader stream-reader) count &key (timeout-ms 0))
  (multiple-value-bind (cffi-type element-type)
      (%sample-array-type (value-read-type reader))
    (cffi:with-foreign-object (buffer cffi-type (max count 1))
      (%buffer->vector buffer cffi-type element-type
                       (stream-reader-read reader buffer count timeout-ms)))))

(defmethod read ((reader tail-reader) count &key timeout-ms)
  (declare (ignore timeout-ms))
  (multiple-value-bind (cffi-type element-type)
      (%sample-array-type (value-read-type reader))
    (cffi:with-foreign-object (buffer cffi-type (max count 1))
      (%buffer->vector buffer cffi-type element-type
                       (tail-reader-read reader buffer count)))))

(defmethod read ((reader block-reader) count &key (timeout-ms 0))
  (let ((block-size (block-size reader)))
    (multiple-value-bind (cffi-type element-type)
        (%sample-array-type (value-read-type reader))
      (cffi:with-foreign-object (buffer cffi-type (max (* count block-size) 1))
        (let ((blocks-read (block-reader-read reader buffer count timeout-ms)))
          (%buffer->matrix buffer cffi-type element-type blocks-read block-size))))))

(defgeneric read-with-domain (reader count &key timeout-ms)
  (:documentation
   "Like READ, but also reads the domain (e.g. timestamp) values.  Returns two
vectors as multiple values: the sample values and the domain values, sized to
the same actual sample count."))

(defmethod read-with-domain ((reader stream-reader) count &key (timeout-ms 0))
  (multiple-value-bind (value-type value-element-type)
      (%sample-array-type (value-read-type reader))
    (multiple-value-bind (domain-type domain-element-type)
        (%sample-array-type (domain-read-type reader))
      (cffi:with-foreign-object (values value-type (max count 1))
        (cffi:with-foreign-object (domain domain-type (max count 1))
          (let ((read-count (stream-reader-read-with-domain reader values domain count timeout-ms)))
            (cl:values (%buffer->vector values value-type value-element-type read-count)
                       (%buffer->vector domain domain-type domain-element-type read-count))))))))

(defmethod read-with-domain ((reader tail-reader) count &key timeout-ms)
  (declare (ignore timeout-ms))
  (multiple-value-bind (value-type value-element-type)
      (%sample-array-type (value-read-type reader))
    (multiple-value-bind (domain-type domain-element-type)
        (%sample-array-type (domain-read-type reader))
      (cffi:with-foreign-object (values value-type (max count 1))
        (cffi:with-foreign-object (domain domain-type (max count 1))
          (let ((read-count (tail-reader-read-with-domain reader values domain count)))
            (cl:values (%buffer->vector values value-type value-element-type read-count)
                       (%buffer->vector domain domain-type domain-element-type read-count))))))))

(defmethod read-with-domain ((reader block-reader) count &key (timeout-ms 0))
  (let ((block-size (block-size reader)))
    (multiple-value-bind (value-type value-element-type)
        (%sample-array-type (value-read-type reader))
      (multiple-value-bind (domain-type domain-element-type)
          (%sample-array-type (domain-read-type reader))
        (cffi:with-foreign-object (values value-type (max (* count block-size) 1))
          (cffi:with-foreign-object (domain domain-type (max (* count block-size) 1))
            (let ((blocks-read (block-reader-read-with-domain reader values domain count timeout-ms)))
              (cl:values (%buffer->matrix values value-type value-element-type blocks-read block-size)
                         (%buffer->matrix domain domain-type domain-element-type blocks-read block-size)))))))))

;;; ---------------------------------------------------------------------------
;;; Data packet buffer accessors
;;;
;;; daqDataPacket_getData and daqDataPacket_getRawData return their sample buffer
;;; through a void** out parameter, which the mechanical generator cannot model
;;; (and whose element type is only known at runtime from the packet's data
;;; descriptor).  Those two methods are excluded from generation (see
;;; MANUAL_METHODS in the generator) and defined here instead.
;;; ---------------------------------------------------------------------------

(defun %data-packet-buffer (packet getter)
  "Call GETTER (a low-level data-packet/get-* function taking a void** slot) and
return the sample buffer pointer it writes."
  (cffi:with-foreign-object (address :pointer)
    (funcall getter (%require-live-pointer packet) address)
    (cffi:mem-ref address :pointer)))

(defgeneric data (packet)
  (:documentation
   "Return the packet's sample data as a Lisp vector whose element type matches
the packet's data descriptor sample type, sized to the packet's sample count."))

(defmethod data ((packet data-packet))
  (multiple-value-bind (cffi-type element-type)
      (%sample-array-type (sample-type (data-descriptor packet)))
    (%buffer->vector (%data-packet-buffer packet #'opendaq.low-level:data-packet/get-data)
                     cffi-type element-type (sample-count packet))))

(defgeneric raw-data (packet)
  (:documentation
   "Return the packet's raw (pre-scaling) memory as an (UNSIGNED-BYTE 8) vector.
Reinterpret it via the data descriptor when a typed view is needed; for decoded
values use DATA."))

(defmethod raw-data ((packet data-packet))
  (%buffer->vector (%data-packet-buffer packet #'opendaq.low-level:data-packet/get-raw-data)
                   :uint8 '(unsigned-byte 8) (raw-data-size packet)))

;;; ---------------------------------------------------------------------------
;;; Object helpers
;;; ---------------------------------------------------------------------------

(defun as-list (object-list)
  "Convert an openDAQ object-list into a proper Lisp list of wrapped objects.

Items are returned as their base-object wrappers.  Use AS to cast them to a
more specific type when needed:

  (mapcar (lambda (d) (connection-string (as d 'device-info)))
          (as-list (available-devices root-device)))"
  (loop for i below (count object-list)
        collect (item-at object-list i)))

(defun as (object target-type)
  "Reinterpret a base openDAQ object as a more specific type.

Adds a reference so the returned wrapper owns its own lifetime.
TARGET-TYPE is a symbol naming the wrapper class (e.g. 'DEVICE-INFO)."
  (let ((class (if (symbolp target-type)
                   (find-class target-type)
                   target-type)))
    (add-ref object)
    (make-instance class :pointer (raw-pointer object))))

(defun as-list-of (object-list target-type)
  "Convert an openDAQ object-list into a proper Lisp list, unboxing primitives
(integers, booleans, floats, strings, ratios, complex numbers) into
their native Lisp equivalents and casting objects to TARGET-TYPE.

  Example: (as-list-of (wrap-object-list pointer) 'device-info)
            => (#<DEVICE-INFO ...> #<DEVICE-INFO ...>)

  Example: (as-list-of (wrap-object-list pointer) 'daq-integer)
            => (1 2 3)"
  (if (primitive-type-p target-type)
      (loop for i below (count object-list)
            for obj = (item-at object-list i)
            collect (%unbox-primitive obj target-type))
      (loop for i below (count object-list)
            collect (as (item-at object-list i) target-type))))

(defun as-hashtable-of (dict key-type value-type)
  "Convert an openDAQ dict into a Lisp hash-table.  Keys and values are
unboxed if their type is a primitive, or cast via AS otherwise.

  Example: (as-hashtable-of (wrap-dict pointer) 'string 'device-info)
            => #<HASH-TABLE>"
  (let* ((raw (%require-live-pointer dict))
         (key-list (opendaq.low-level:dict/get-key-list raw))
         (n (opendaq.low-level:list/get-count key-list))
         (ht (make-hash-table :test 'equal :size n)))
    (loop for i below n
          for key-ptr = (opendaq.low-level:list/get-item-at key-list i)
          for val-ptr = (opendaq.low-level:dict/get raw key-ptr)
          for key-obj = (wrap-base-object key-ptr)
          for key = (if (primitive-type-p key-type)
                       (%unbox-primitive key-obj key-type)
                       (as key-obj key-type))
          for val-obj = (wrap-base-object val-ptr)
          for val = (if (primitive-type-p value-type)
                       (%unbox-primitive val-obj value-type)
                       (as val-obj value-type))
          do (setf (gethash key ht) val))
    ht))
