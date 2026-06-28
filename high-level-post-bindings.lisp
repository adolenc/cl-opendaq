;;;; Hand-written high-level layer, loaded after generated/high-level-bindings.lisp.
;;;;
;;;; The generated bindings are a mechanical 1:1 mapping of the C API.  This file
;;;; holds the hand-written pieces that build on top of them:
;;;;
;;;;   * sample-buffer helpers  — convert openDAQ's untyped (void*) buffers, whose
;;;;                              element type is only known at runtime, into typed
;;;;                              Lisp vectors
;;;;   * reader convenience API — READ / READ-WITH-DOMAIN / READ-SAMPLES
;;;;   * data packet accessors  — DATA / RAW-DATA (excluded from generation; see
;;;;                              MANUAL_METHODS in the generator)
;;;;   * object helpers         — AS / AS-LIST
;;;;
;;;; Code that must load *before* the generated bindings lives in runtime.lisp
;;;; (its high-level runtime section).

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
vector for stream/tail readers, a 2-D (blocks x block-size) array for block
readers, or a list of one vector per signal for multi readers."))

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
   "Like READ, but also reads the domain (e.g. timestamp) values.  Returns the
sample values and the domain values as two parallel results (multiple values),
each sized to the same actual sample count: vectors for the single-signal
readers, or a list of one vector per signal for multi readers."))

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
;;; Multi reader
;;;
;;; A multi reader reads several signals at once, aligned on a common domain.
;;; Unlike the single-buffer readers above it fills one value (and one domain)
;;; buffer *per signal* -- the C API takes a void**, an array of buffer pointers.
;;; We accept the signals as a plain Lisp list at construction and return one
;;; Lisp vector per signal from READ / READ-WITH-DOMAIN, so callers never have to
;;; touch the foreign buffers.
;;; ---------------------------------------------------------------------------

(defmethod initialize-instance :around ((reader multi-reader) &rest initargs &key signals &allow-other-keys)
  "Let :SIGNALS be a plain Lisp list of signals (as well as an object-list),
building the object-list the underlying constructor expects.  The original
:SIGNALS is left in INITARGS but overridden by the leftmost one we prepend."
  (if (and signals (listp signals))
      (let ((object-list (make-instance 'object-list)))
        (dolist (signal signals)
          (push-back object-list signal))
        (apply #'call-next-method reader :signals object-list initargs))
      (call-next-method)))

(defun %multi-reader-signal-count (reader)
  "Number of signals READER was constructed with.  IMultiReader exposes no
signal-count accessor, so we count the :SIGNALS object-list the constructor
stashed in the class slot of the same name."
  (let ((signals (slot-value reader '%signals-initarg)))
    (unless signals
      (error "Cannot determine the signal count of ~S; multi-reader READ needs a ~
reader created with MAKE-INSTANCE and :SIGNALS." reader))
    (count signals)))

(defmacro %with-multi-reader-buffers ((array-var buffers-var signal-count cffi-type sample-count) &body body)
  "Allocate SIGNAL-COUNT foreign buffers of SAMPLE-COUNT elements of CFFI-TYPE and
a void** ARRAY-VAR pointing at them (one buffer per signal), run BODY with
ARRAY-VAR and BUFFERS-VAR bound, and free everything afterwards."
  (let ((index (gensym "INDEX"))
        (count (gensym "COUNT")))
    `(let* ((,count ,signal-count)
            (,buffers-var (loop repeat ,count
                                collect (cffi:foreign-alloc ,cffi-type :count (max ,sample-count 1)))))
       (unwind-protect
            (cffi:with-foreign-object (,array-var :pointer ,count)
              (loop for ,index below ,count
                    do (setf (cffi:mem-aref ,array-var :pointer ,index) (nth ,index ,buffers-var)))
              ,@body)
         (mapc #'cffi:foreign-free ,buffers-var)))))

(defmethod read ((reader multi-reader) count &key (timeout-ms 0))
  (let ((signal-count (%multi-reader-signal-count reader)))
    (multiple-value-bind (cffi-type element-type)
        (%sample-array-type (value-read-type reader))
      (%with-multi-reader-buffers (value-array value-buffers signal-count cffi-type count)
        (let ((read-count (multi-reader-read reader value-array count timeout-ms)))
          (mapcar (lambda (buffer) (%buffer->vector buffer cffi-type element-type read-count))
                  value-buffers))))))

(defmethod read-with-domain ((reader multi-reader) count &key (timeout-ms 0))
  (let ((signal-count (%multi-reader-signal-count reader)))
    (multiple-value-bind (value-type value-element-type)
        (%sample-array-type (value-read-type reader))
      (multiple-value-bind (domain-type domain-element-type)
          (%sample-array-type (domain-read-type reader))
        (%with-multi-reader-buffers (value-array value-buffers signal-count value-type count)
          (%with-multi-reader-buffers (domain-array domain-buffers signal-count domain-type count)
            (let ((read-count (multi-reader-read-with-domain
                               reader value-array domain-array count timeout-ms)))
              (cl:values
               (mapcar (lambda (b) (%buffer->vector b value-type value-element-type read-count)) value-buffers)
               (mapcar (lambda (b) (%buffer->vector b domain-type domain-element-type read-count)) domain-buffers)))))))))

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

(defun as (object target-type)
  "Reinterpret a base openDAQ OBJECT as the more specific type TARGET-TYPE, returning
a wrapper of that type.  Adds a reference so the result owns its own lifetime.  Only
valid when OBJECT really is that type (it is an unchecked cast, not a query -- see
IS-P / COMPONENT-TYPE to test first).  TARGET-TYPE is a symbol naming
the class (e.g. 'DEVICE-INFO).

For a boxed primitive this returns the typed wrapper (e.g. an INTEGER-OBJECT), not
the Lisp value; UNBOX the result to get the value: (unbox (as x 'integer-object))."
  (let ((class (if (symbolp target-type)
                   (find-class target-type)
                   target-type)))
    (add-ref object)
    (make-instance class :pointer (raw-pointer object))))

(defun unbox (object)
  "Return the native Lisp value of a boxed-primitive wrapper OBJECT: an integer,
float, string, boolean, ratio, or complex number.  OBJECT's own class names the
primitive, so for a generic BASE-OBJECT (e.g. a property value, or a value pulled
from a dict or a core event's PARAMETERS) cast it to the expected type first:

  (unbox an-integer-object)                       => 42
  (unbox (as (gethash \"Name\" params) 'string-object)) => \"Frequency\"

OBJECT is left intact (its reference is still released by the GC)."
  ;; CL:CLASS-NAME: the high-level package shadows CLASS-NAME with openDAQ's
  ;; getClassName generic, so the Lisp accessor must be qualified.
  (let ((type (cl:class-name (class-of object))))
    (unless (primitive-type-p type)
      (error "UNBOX needs a boxed-primitive wrapper, but ~S is a ~S.  AS it to a ~
primitive type first, e.g. (unbox (as object 'integer-object))." object type))
    (%boxed-value object type)))

(defun %as-consuming (object target-type)
  "Like AS, but for a fresh ITEM-AT / DICT temporary the caller owns and will not
otherwise release.  For a primitive TARGET-TYPE the value is read and the temporary
released immediately, rather than left to the GC; for a managed TARGET-TYPE AS adds
its own reference and the temporary is released by the GC, as before."
  (if (primitive-type-p target-type)
      (%unbox-primitive object target-type)
      (as object target-type)))

(defparameter *queryable-component-types*
  '(channel function-block device signal input-port folder component)
  "Component interface types, most-derived first, that COMPONENT-TYPE tries.")

(defun %interface-id-getter (type)
  "The low-level <TYPE>/get-interface-id function for the class symbol TYPE."
  (or (find-symbol (concatenate 'string (symbol-name type) "/GET-INTERFACE-ID")
                   '#:opendaq.low-level)
      (error "No interface-id getter for type ~S." type)))

(defun is-p (object type)
  "True if OBJECT is a TYPE, i.e. implements the openDAQ interface named by the
class symbol TYPE (e.g. 'CHANNEL, 'SIGNAL, 'FOLDER).  Unlike AS, this performs a
real interface query, so it is safe to ask about any type."
  (opendaq.low-level::%supports-interface-p
   (%require-live-pointer object)
   (%interface-id-getter type)))

(defun component-type (object &optional (candidates *queryable-component-types*))
  "The most-derived interface among CANDIDATES that OBJECT implements, as a
class symbol (e.g. CHANNEL), or NIL if none.  Lets you discover a component's
concrete type without an unsafe reinterpreting cast."
  (find-if (lambda (type) (is-p object type)) candidates))

(defun as-list-of (object-list target-type)
  "Convert an openDAQ object-list into a proper Lisp list, unboxing primitives
(integers, booleans, floats, strings, ratios, complex numbers) into
their native Lisp equivalents and casting objects to TARGET-TYPE.

  Example: (as-list-of (wrap pointer 'object-list) 'device-info)
            => (#<DEVICE-INFO ...> #<DEVICE-INFO ...>)

  Example: (as-list-of (wrap pointer 'object-list) 'integer-object)
            => (1 2 3)"
  (loop for i below (count object-list)
        collect (%as-consuming (item-at object-list i) target-type)))

(defun as-hashtable-of (dict key-type value-type)
  "Convert an openDAQ dict into a Lisp hash-table.  Keys and values are
unboxed if their type is a primitive, or cast via AS otherwise.

  Example: (as-hashtable-of (wrap pointer 'dict) 'string 'device-info)
            => #<HASH-TABLE>"
  (let* ((raw (%require-live-pointer dict))
         (key-list (opendaq.low-level:dict/get-key-list raw))
         (n (opendaq.low-level:list/get-count key-list))
         (ht (make-hash-table :test 'equal :size n)))
    (loop for i below n
          for key-ptr = (opendaq.low-level:list/get-item-at key-list i)
          for val-ptr = (opendaq.low-level:dict/get raw key-ptr)
          for key = (%as-consuming (wrap key-ptr 'base-object) key-type)
          for val = (%as-consuming (wrap val-ptr 'base-object) value-type)
          do (setf (gethash key ht) val))
    ht))

(defparameter *core-type-classes*
  '((:daq-ct-bool           . boolean-object)
    (:daq-ct-int            . integer-object)
    (:daq-ct-float          . float-object)
    (:daq-ct-string         . string-object)
    (:daq-ct-ratio          . ratio-object)
    (:daq-ct-complex-number . complex-number-object))
  "Maps a DAQ-CORE-TYPE keyword to the boxed-primitive class a value of that type
casts to.  Only the scalar core types appear; the rest (list, dict, struct, object,
proc, func, ...) are not single boxed values and so map to NIL.")

(defun core-type->class (core-type)
  "The boxed-primitive class a value of CORE-TYPE casts to, or NIL when CORE-TYPE is
not a scalar.  CORE-TYPE is a DAQ-CORE-TYPE keyword (:daq-ct-int, :daq-ct-string,
...), as returned by VALUE-TYPE; the result is the class symbol to hand to AS:

  (let ((class (core-type->class (value-type property))))
    (if class
        (unbox (as (property-value object (name property)) class))  ; a scalar value
        ...))                                                       ; structured

This is the bridge between the type a property/list/dict reports and the wrapper
class the conversion functions take; NIL doubles as a \"not a scalar\" predicate."
  (cdr (assoc core-type *core-type-classes*)))

;;; ---------------------------------------------------------------------------
;;; Domain timestamps
;;;
;;; A domain signal reports plain integer ticks.  Turning a tick into wall-clock
;;; time needs two pieces of metadata: the domain origin (an absolute epoch, as
;;; an ISO-8601 string) and the tick resolution (seconds per tick, a ratio), so
;;; that:  absolute-time = origin + tick * tick-resolution.  These helpers read
;;; that metadata off a domain source and convert ticks into LOCAL-TIME
;;; timestamps, which callers can then format however they like.
;;; ---------------------------------------------------------------------------

(defun %domain-time-converter (origin resolution)
  "Build the tick->timestamp closure from a raw ORIGIN string and RESOLUTION
ratio (seconds per tick)."
  (let ((origin-unix (local-time:timestamp-to-unix (local-time:parse-timestring origin)))
        (seconds-per-tick (/ (numerator resolution) (denominator resolution))))
    (lambda (tick)
      (multiple-value-bind (whole-seconds fractional-seconds)
          (floor (+ origin-unix (* tick seconds-per-tick)))     ; exact rational
        (local-time:unix-to-timestamp
         whole-seconds :nsec (round (* fractional-seconds 1000000000)))))))

(defgeneric domain-time-converter (source)
  (:documentation
   "Return a one-argument function mapping a domain tick (an integer) to an
absolute LOCAL-TIME:TIMESTAMP.  SOURCE supplies the domain metadata and may be a
DATA-DESCRIPTOR, a SIGNAL (its domain signal's descriptor is used), or a
MULTI-READER (its common domain is used).  The origin and resolution are read
once, so reuse the returned closure when converting many ticks."))

(defmethod domain-time-converter ((source data-descriptor))
  (%domain-time-converter (origin source) (tick-resolution source)))

(defmethod domain-time-converter ((source multi-reader))
  (%domain-time-converter (origin source) (tick-resolution source)))

(defmethod domain-time-converter ((source signal))
  (domain-time-converter (descriptor (domain-signal source))))

(defun domain-tick->timestamp (source tick)
  "Convert a single domain TICK from SOURCE to an absolute LOCAL-TIME:TIMESTAMP.
Prefer DOMAIN-TIME-CONVERTER when converting many ticks, to avoid re-reading
SOURCE's domain metadata each time, e.g.:

  (map 'vector (domain-time-converter source) domain-ticks)"
  (funcall (domain-time-converter source) tick))

;;; ---------------------------------------------------------------------------
;;; Event handlers from Lisp functions
;;;
;;; openDAQ's event callback (daqEventCall) is `void (BaseObject* sender,
;;; BaseObject* args)' with no user-data argument, and portable CFFI cannot turn
;;; a Lisp closure into a C function pointer.  So each subscribed function needs
;;; its own C trampoline that knows which function to call.  We COMPILE one on
;;; demand -- a CFFI:DEFCALLBACK baked with a slot index that routes to the
;;; stored function -- and return its slot to a free list on REMOVE-HANDLER for
;;; reuse.  There is thus no fixed limit; a stable set of handlers settles on a
;;; stable set of trampolines (one per concurrently-live handler at the peak).
;;;
;;; Refcounts take care of themselves: the C binding add-refs sender and args
;;; before calling us (handing the callback ownership of one reference to each),
;;; and wrapping them as managed objects lets the GC finalizers release exactly
;;; those references -- so a handler function never has to release anything.
;;; ---------------------------------------------------------------------------

(defvar *event-callback-functions* (make-array 16 :adjustable t :fill-pointer 0)
  "Slot vector: entry I holds the Lisp function invoked by trampoline I, or NIL when free.")

(defvar *event-callback-pointers* (make-array 16 :adjustable t :fill-pointer 0)
  "Foreign pointer of the trampoline compiled for each slot, indexed by slot.")

(defvar *free-event-callback-slots* '()
  "Indices of slots whose handler was removed and whose trampoline can be reused.")

(defvar *event-handler-callback-indices*
  (trivial-garbage:make-weak-hash-table :weakness :key :test 'eq)
  "Maps a function-backed EVENT-HANDLER to its slot, so REMOVE-HANDLER can free it.")

(defun %dispatch-event-callback (index sender args)
  (let ((function (aref *event-callback-functions* index)))
    (when function
      (funcall function (wrap sender 'base-object) (wrap args 'base-object)))))

(defun %make-event-trampoline (index)
  "Compile a fresh daqEventCall C trampoline routing to slot INDEX.  Built with
COMPILE (rather than a fixed pre-built pool) so any number of distinct handlers
is supported on any CFFI-capable Lisp."
  (let ((name (gensym "EVENT-CALLBACK")))
    (funcall (compile nil `(lambda ()
                             (cffi:defcallback ,name :void ((sender :pointer) (args :pointer))
                               (%dispatch-event-callback ,index sender args)))))
    (cffi:get-callback name)))

(defun %allocate-event-callback (function)
  "Reserve a trampoline slot for FUNCTION -- reusing a freed slot or growing the
table by compiling a new trampoline -- and return its foreign pointer and index."
  (let ((index (or (pop *free-event-callback-slots*)
                   (let ((new-index (fill-pointer *event-callback-functions*)))
                     (vector-push-extend nil *event-callback-functions*)
                     (vector-push-extend (%make-event-trampoline new-index) *event-callback-pointers*)
                     new-index))))
    (setf (aref *event-callback-functions* index) function)
    (cl:values (aref *event-callback-pointers* index) index)))

(defmethod initialize-instance :around ((handler event-handler) &rest initargs &key function &allow-other-keys)
  "Let :FUNCTION be a Lisp function of (SENDER ARGS), called when the event fires,
as an alternative to the raw :CALL foreign pointer.  SENDER and ARGS arrive as
managed objects whose references the GC releases, so the function need not clean
anything up; cast ARGS with AS for typed event args (e.g. to CORE-EVENT-ARGS)."
  (if function
      (multiple-value-bind (pointer index) (%allocate-event-callback function)
        (let ((instance (apply #'call-next-method handler :call pointer initargs)))
          (setf (gethash instance *event-handler-callback-indices*) index)
          instance))
      (call-next-method)))

(defmethod add-handler ((object event) (handler function))
  "Subscribe a Lisp function directly: HANDLER is wrapped in an EVENT-HANDLER and
called with the wrapped SENDER and ARGS each time the event fires.  Returns the
created EVENT-HANDLER, which may be passed to REMOVE-HANDLER to unsubscribe."
  (let ((event-handler (make-instance 'event-handler :function handler)))
    (add-handler object event-handler)
    event-handler))

(defmethod remove-handler :after ((object event) (handler event-handler))
  "Free HANDLER's trampoline slot for reuse once it is unsubscribed."
  (let ((index (gethash handler *event-handler-callback-indices*)))
    (when index
      (setf (aref *event-callback-functions* index) nil)
      (push index *free-event-callback-slots*)
      (remhash handler *event-handler-callback-indices*))))
