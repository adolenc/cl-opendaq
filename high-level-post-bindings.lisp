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
;;;;   * object helpers         — AS / UNBOX / TYPEP / COMPONENT-TYPE
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

(defun %numeric-sample-layout (sample-type)
  "Describe how SAMPLE-TYPE's samples sit in a flat numeric buffer, as
(VALUES cffi-type element-type complexp): the foreign element type, the Lisp type
of one component, and whether each sample is a COMPLEX number stored as an
interleaved (real, imaginary) pair of that element type.  Signals an error for
sample types that are not a flat numeric buffer (e.g. binary, string, struct,
range, or the invalid/undefined sentinels), which these accessors cannot model."
  (case sample-type
    (:float64        (cl:values :double 'double-float nil))
    (:float32        (cl:values :float  'single-float nil))
    (:int8           (cl:values :int8   '(signed-byte 8) nil))
    (:uint8          (cl:values :uint8  '(unsigned-byte 8) nil))
    (:int16          (cl:values :int16  '(signed-byte 16) nil))
    (:uint16         (cl:values :uint16 '(unsigned-byte 16) nil))
    (:int32          (cl:values :int32  '(signed-byte 32) nil))
    (:uint32         (cl:values :uint32 '(unsigned-byte 32) nil))
    (:int64          (cl:values :int64  '(signed-byte 64) nil))
    (:uint64         (cl:values :uint64 '(unsigned-byte 64) nil))
    (:complexfloat32 (cl:values :float  'single-float t))
    (:complexfloat64 (cl:values :double 'double-float t))
    (t (error "openDAQ sample type ~S is not a flat numeric buffer; the data accessors handle the integer, float, and complex-float sample types."
              sample-type))))

(defun %sample-array-type (sample-type &optional allow-complex)
  "Map a numeric openDAQ SAMPLE-TYPE keyword to (VALUES cffi-type
lisp-element-type complexp), as the streaming readers need.  Unless
ALLOW-COMPLEX, errors on complex sample types (which the caller cannot return)."
  (multiple-value-bind (cffi-type element-type complexp) (%numeric-sample-layout sample-type)
    (when (and complexp (not allow-complex))
      (error "openDAQ sample type ~S is complex; this reader cannot return complex samples." sample-type))
    (cl:values cffi-type element-type complexp)))

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

(defun %buffer->complex-vector (buffer cffi-type element-type count)
  "Build a COUNT-element vector of COMPLEX numbers from BUFFER, which holds COUNT
interleaved (real, imaginary) pairs of CFFI-TYPE."
  (let ((result (make-array count :element-type (cl:list 'cl:complex element-type))))
    (dotimes (index count result)
      (setf (aref result index)
            (cl:complex (cffi:mem-aref buffer cffi-type (* 2 index))
                        (cffi:mem-aref buffer cffi-type (1+ (* 2 index))))))))

(defun %buffer->samples (buffer cffi-type element-type samples width &optional complexp)
  "Copy SAMPLES samples of WIDTH values each out of foreign BUFFER: a flat vector
when WIDTH is 1, else a (SAMPLES x WIDTH) matrix with one row per sample.  With
COMPLEXP the buffer holds interleaved (real, imaginary) pairs per value instead."
  (cond ((and complexp (> width 1))
         (error "Reading complex samples from a dimensioned signal is not supported."))
        (complexp (%buffer->complex-vector buffer cffi-type element-type samples))
        ((= width 1) (%buffer->vector buffer cffi-type element-type samples))
        (t (%buffer->matrix buffer cffi-type element-type samples width))))

(defun %sequence->buffer (buffer cffi-type element-type sequence)
  "Write SEQUENCE's elements (any Lisp sequence -- list or vector) into the foreign
BUFFER as CFFI-TYPE, coercing each to ELEMENT-TYPE (a real to the buffer's float
type, or rounded to its integer type).  The buffer must be large enough to hold
them; returns the count written."
  (let ((index 0)
        (floatp (subtypep element-type 'cl:float)))
    (map nil
         (lambda (value)
           (setf (cffi:mem-aref buffer cffi-type index)
                 (if floatp (cl:coerce value element-type) (round value)))
           (incf index))
         sequence)
    index))

(defun %complex-sequence->buffer (buffer cffi-type element-type sequence)
  "Write SEQUENCE's elements (any Lisp sequence) into BUFFER as interleaved
(real, imaginary) pairs of CFFI-TYPE, coercing each component to ELEMENT-TYPE.  A
real element is written with a zero imaginary part.  Returns the count written."
  (let ((index 0))
    (map nil
         (lambda (value)
           (setf (cffi:mem-aref buffer cffi-type (* 2 index))
                 (cl:coerce (realpart value) element-type)
                 (cffi:mem-aref buffer cffi-type (1+ (* 2 index)))
                 (cl:coerce (imagpart value) element-type))
           (incf index))
         sequence)
    index))

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
          (value-read-type :float64)
          (domain-read-type :int64)
          (mode :scaled)
          (timeout-type :all)
          ;; Off so READ sees descriptor-changed events and can track the value
          ;; sample width (see the "Value sample width" section below).
          (skip-events nil)
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
          (value-read-type :float64)
          (domain-read-type :int64)
          (mode :scaled)
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
          (value-read-type :float64)
          (domain-read-type :int64)
          (mode :scaled)
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

;;; ---------------------------------------------------------------------------
;;; Value sample width (dimensioned "2-D" signals, e.g. FFT amplitude spectra)
;;;
;;; Each sample of a dimensioned signal packs one value per dimension point, so
;;; reads must size their buffer to COUNT * width and return a (samples x width)
;;; matrix.  The width must match the descriptor the *reader* is decoding, which
;;; can lag the signal's (the reader drains a packet queue); sizing from the
;;; signal would race a mid-stream descriptor change and overflow the buffer.
;;; So stream readers keep skip-events off and track the width from their own
;;; DATA_DESCRIPTOR_CHANGED events: the samples a read returns belong to the
;;; pre-event descriptor, and the event announces the width of the next batch.
;;; ---------------------------------------------------------------------------

(defun %descriptor-sample-width (descriptor)
  "Number of scalar values in one sample described by DESCRIPTOR: the size of its
single dimension (e.g. a spectrum's bin count), or 1 otherwise -- mirroring the
openDAQ readers, which only unpack exactly one dimension."
  (let ((dimensions (and descriptor (dimensions descriptor))))
    (if (= 1 (cl:length dimensions))
        (size (first dimensions))
        1)))

(defun %reader-value-sample-width (reader)
  "Value sample width per READER's signal's current descriptor (1 without a signal)."
  (let ((signal (slot-value reader '%signal-initarg)))
    (if signal (%descriptor-sample-width (descriptor signal)) 1)))

(defvar *stream-reader-value-width*
  (trivial-garbage:make-weak-hash-table :weakness :key :test 'eq)
  "Per-stream-reader cache of the width the reader is currently decoding, advanced
from its descriptor-changed events.  Weak so it never keeps a reader alive.")

(defun %event-value-width (status)
  "The value sample width announced by reader STATUS's descriptor-changed event,
or NIL when STATUS is not an event or its event carries no value descriptor."
  (when (and status (eq (read-status status) :event))
    (let* ((event (event-packet status))
           (descriptor (and event (gethash "DataDescriptor" (parameters event)))))
      (when descriptor
        (%descriptor-sample-width (as descriptor 'data-descriptor))))))

(define-condition reader-invalidated (error)
  ((reader :initarg :reader :reader reader-invalidated-reader))
  (:report (lambda (condition stream)
             (format stream "openDAQ reader ~S was invalidated by a descriptor change it cannot convert; recover by building a FROM-EXISTING reader from it with matching read types."
                     (reader-invalidated-reader condition))))
  (:documentation "Signalled by READ / READ-WITH-DOMAIN when a signal's data
descriptor changed to a sample type the reader cannot convert to its read type.
The reader keeps the unread packets; build e.g. a STREAM-READER/FROM-EXISTING
from it (with read types matching the new descriptor) to continue reading."))

(defun %stream-read-tracking-width (reader read-into-buffer)
  "Call READ-INTO-BUFFER with the value sample width to size the read by, and
return its RESULT.  READ-INTO-BUFFER performs one low-level read into a buffer of
that width and returns (VALUES RESULT SAMPLES-READ STATUS).  Any descriptor event
in STATUS announces the width of the *next* batch, so we cache it per reader; we
re-read past every zero-sample event (the reader's initial one, and any later
descriptor change such as a sample-rate change whose event carries no value
descriptor), and only surface an empty result for a genuine no-data read."
  (loop with width = (multiple-value-bind (cached presentp)
                         (gethash reader *stream-reader-value-width*)
                       ;; The signal is only the initial guess; events take over.
                       (if presentp cached (%reader-value-sample-width reader)))
        repeat 1024
        for (result samples-read status) = (multiple-value-list (funcall read-into-buffer width))
        for event-width = (%event-value-width status)
        do (cond
             ((plusp samples-read)
              (when event-width (setf (gethash reader *stream-reader-value-width*) event-width))
              (return result))
             ;; Checked before the event branch: an invalidating event also
             ;; carries a descriptor, but re-reading an invalid reader can never
             ;; succeed.
             ((and status (not (valid status)))
              (error 'reader-invalidated :reader reader))
             ;; A zero-sample descriptor-changed event: skip past it and re-read.
             ;; It may announce a new value width (dimensioned signal) or only a
             ;; domain change (e.g. a sample-rate change, whose value descriptor
             ;; is null and so yields no EVENT-WIDTH) -- either way keep reading
             ;; rather than surface an empty result.
             ((and status (eq (read-status status) :event))
              (when event-width
                (setf width event-width
                      (gethash reader *stream-reader-value-width*) event-width)))
             ;; Genuine zero-sample read (e.g. a timeout with no data).
             (t (return result)))
        finally (return result)))

(defgeneric read (reader count &key timeout-ms)
  (:documentation
   "Read up to COUNT samples (or COUNT blocks, for a block reader) from READER.
Returns a Lisp array whose element type matches the reader's VALUE-READ-TYPE:
a vector for stream/tail readers on a scalar signal; a 2-D (samples x sample-width)
array, one row per sample, for stream/tail readers on a dimensioned signal (e.g.
an FFT amplitude spectrum); a 2-D (blocks x block-size) array for block readers;
or a list of one vector per signal for multi readers."))

(defmethod read ((reader stream-reader) count &key (timeout-ms 0))
  (multiple-value-bind (cffi-type element-type complexp)
      (%sample-array-type (value-read-type reader) t)
    (%stream-read-tracking-width
     reader
     (lambda (width)
       (cffi:with-foreign-object (buffer cffi-type (max (* count width (if complexp 2 1)) 1))
         (multiple-value-bind (samples-read status)
             (stream-reader-read reader buffer count timeout-ms)
           (cl:values (%buffer->samples buffer cffi-type element-type samples-read width complexp)
                      samples-read status)))))))

(defmethod read ((reader tail-reader) count &key timeout-ms)
  (declare (ignore timeout-ms))
  (multiple-value-bind (cffi-type element-type)
      (%sample-array-type (value-read-type reader))
    (let ((width (%reader-value-sample-width reader)))
      (cffi:with-foreign-object (buffer cffi-type (max (* count width) 1))
        (%buffer->samples buffer cffi-type element-type
                          (tail-reader-read reader buffer count) width)))))

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
sample values and the domain values as two parallel results (multiple values):
for the single-signal readers the values follow READ's shape (a vector, or a
(samples x sample-width) matrix for a dimensioned signal) while the domain is
always a vector of one tick per sample; for multi readers, a list of one vector
per signal for each.  Both results are sized to the same actual sample count."))

(defmethod read-with-domain ((reader stream-reader) count &key (timeout-ms 0))
  (multiple-value-bind (value-type value-element-type complexp)
      (%sample-array-type (value-read-type reader) t)
    (multiple-value-bind (domain-type domain-element-type)
        (%sample-array-type (domain-read-type reader))
      (cl:values-list
       (%stream-read-tracking-width
        reader
        (lambda (width)
          (cffi:with-foreign-object (values value-type (max (* count width (if complexp 2 1)) 1))
            (cffi:with-foreign-object (domain domain-type (max count 1))
              (multiple-value-bind (samples-read status)
                  (stream-reader-read-with-domain reader values domain count timeout-ms)
                (cl:values (cl:list (%buffer->samples values value-type value-element-type samples-read width complexp)
                                    (%buffer->vector domain domain-type domain-element-type samples-read))
                           samples-read status))))))))))

(defmethod read-with-domain ((reader tail-reader) count &key timeout-ms)
  (declare (ignore timeout-ms))
  (multiple-value-bind (value-type value-element-type)
      (%sample-array-type (value-read-type reader))
    (multiple-value-bind (domain-type domain-element-type)
        (%sample-array-type (domain-read-type reader))
      (let ((width (%reader-value-sample-width reader)))
        (cffi:with-foreign-object (values value-type (max (* count width) 1))
          (cffi:with-foreign-object (domain domain-type (max count 1))
            (let ((samples-read (tail-reader-read-with-domain reader values domain count)))
              (cl:values (%buffer->samples values value-type value-element-type samples-read width)
                         (%buffer->vector domain domain-type domain-element-type samples-read)))))))))

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
      (error "Cannot determine the signal count of ~S; multi-reader READ needs a reader created with MAKE-INSTANCE and :SIGNALS." reader))
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
   "Return the packet's sample data as a Lisp vector, sized to the packet's sample
count, whose element type follows the packet's data descriptor sample type: a
typed vector of integers or floats for the scalar numeric sample types, or a
vector of COMPLEX numbers for the complex-float sample types.  Signals an error for
sample types that are not a flat numeric buffer (binary, string, struct, range)."))

(defmethod data ((packet data-packet))
  (multiple-value-bind (cffi-type element-type complexp)
      (%numeric-sample-layout (sample-type (data-descriptor packet)))
    (let ((buffer (%data-packet-buffer packet #'opendaq.low-level:data-packet/get-data))
          (count (sample-count packet)))
      (if complexp
          (%buffer->complex-vector buffer cffi-type element-type count)
          (%buffer->vector buffer cffi-type element-type count)))))

(defmethod (setf data) (samples (packet data-packet))
  "Write SAMPLES into PACKET's sample buffer in place.  SAMPLES is any Lisp sequence
(a list or a vector); each element is coerced to the packet's data descriptor
sample type -- a real to a float type, a rounded integer to an integer type, or a
real/complex split into an interleaved (real, imaginary) pair for the complex-float
sample types.  The packet owns the buffer and must already be sized to hold them
(i.e. its sample count); SAMPLES is returned."
  (multiple-value-bind (cffi-type element-type complexp)
      (%numeric-sample-layout (sample-type (data-descriptor packet)))
    (let ((buffer (%data-packet-buffer packet #'opendaq.low-level:data-packet/get-data)))
      (if complexp
          (%complex-sequence->buffer buffer cffi-type element-type samples)
          (%sequence->buffer buffer cffi-type element-type samples))))
  samples)

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
;;;
;;; The two conversion verbs are split by which world the result lives in: AS
;;; recasts between openDAQ wrappers and never leaves openDAQ; UNBOX crosses into
;;; Lisp, discovering the value's type from the object itself at runtime, so it
;;; needs no type argument.  TYPEP / COMPONENT-TYPE are the safe queries.
;;; %LIST-OF / %HASHTABLE-OF are the statically-typed container converters the
;;; generated getters use; end-user code reaches for UNBOX instead.
;;; ---------------------------------------------------------------------------

(defparameter *interface-name-overrides*
  '((boolean-object        . "BOOLEAN")
    (complex-number-object . "COMPLEX-NUMBER")
    (function-object       . "FUNCTION")
    (integer-object        . "INTEGER")
    (number-object         . "NUMBER")
    (object-list           . "LIST")
    (ratio-object          . "RATIO")
    (string-object         . "STRING")
    (type-object           . "TYPE"))
  "High-level class symbols whose name differs from their openDAQ interface's
low-level prefix, mapped to that prefix.  These are the CLASS_NAME_OVERRIDES
renames in tools/generate_high_level_bindings.py, which suffix CL-colliding names
with -OBJECT.  (FLOAT-OBJECT needs no entry: openDAQ itself names that interface
IFloatObject.)")

(defun %find-interface-id-getter (type)
  "The low-level <TYPE>/get-interface-id function for the class symbol TYPE, or
NIL when the C API exposes no interface id for it (BASE-OBJECT, FUNCTION-OBJECT,
PROCEDURE, and a few other coretypes plumbing interfaces have none)."
  (let ((prefix (or (cdr (assoc type *interface-name-overrides*))
                    (symbol-name type))))
    (find-symbol (concatenate 'string prefix "/GET-INTERFACE-ID")
                 '#:opendaq.low-level)))

(defun %interface-id-getter (type)
  "Like %FIND-INTERFACE-ID-GETTER, but signals an error when TYPE has no
interface-id getter."
  (or (%find-interface-id-getter type)
      (error "No interface-id getter for type ~S." type)))

(defun as (object target-type)
  "Cast the openDAQ OBJECT to the more specific type TARGET-TYPE, returning a
wrapper of that type that owns its own reference.  This is a real interface query
(queryInterface): the wrapper holds the genuine interface pointer -- required
because an object's interfaces live at different vtable offsets, so the pointer
for one is not interface-compatible with another -- and an unsupported
TARGET-TYPE signals an openDAQ error (see TYPEP / COMPONENT-TYPE to test first).
TARGET-TYPE is a symbol naming the class (e.g. 'DEVICE-INFO).

The few coretypes interfaces with no interface id in the C API (BASE-OBJECT,
FUNCTION-OBJECT, PROCEDURE, ...) cannot be queried; for those the pointer is
reinterpreted unchecked, which is sound only when TARGET-TYPE lies on the same
interface inheritance chain as the pointer's current type.

AS never leaves openDAQ: both the input and the result are wrappers.  To get the
native Lisp value of an object, use UNBOX."
  (when (keywordp target-type)
    (error "AS casts to an openDAQ class named by a symbol, e.g. (as x 'signal); to get the native Lisp value of ~S use (unbox ~:*~S) instead." object))
  (let* ((class (if (symbolp target-type)
                    (find-class target-type)
                    target-type))
         (getter (%find-interface-id-getter (cl:class-name class))))
    (if getter
        (make-instance class :pointer (%query-interface (%require-live-pointer object)
                                                        getter))
        (progn
          (add-ref object)
          (make-instance class :pointer (raw-pointer object))))))

(defparameter *unboxable-interfaces*
  '((opendaq.low-level:string/get-interface-id         . string-object)
    (opendaq.low-level:integer/get-interface-id        . integer-object)
    (opendaq.low-level:float/get-interface-id   . float-object)
    (opendaq.low-level:boolean/get-interface-id        . boolean-object)
    (opendaq.low-level:ratio/get-interface-id          . ratio-object)
    (opendaq.low-level:complex-number/get-interface-id . complex-number-object)
    (opendaq.low-level:list/get-interface-id           . :list)
    (opendaq.low-level:dict/get-interface-id           . :dict))
  "The openDAQ interfaces UNBOX probes for, in probe order, each mapped to how its
value converts to Lisp: a boxed-primitive class symbol (read via %READ-BOXED-VALUE)
or :LIST / :DICT for the containers.  Each entry's car is the low-level
<type>/get-interface-id function naming the interface.")

(defun %unboxed-kind (object)
  "Probe the openDAQ OBJECT for an interface with a natural Lisp form.  Returns
(VALUES kind interface): KIND is a boxed-primitive class symbol, :LIST, :DICT, or
NIL when OBJECT has no Lisp form; INTERFACE is the borrowed interface pointer the
value must be read through (not a new reference -- valid only while OBJECT is)."
  (loop with raw = (%require-live-pointer object)
        for (getter . kind) in *unboxable-interfaces*
        for interface = (opendaq.low-level::%borrowed-interface raw getter)
        when interface
          return (cl:values kind interface)
        finally (return (cl:values nil nil))))

(defun %unbox-daq-list (list-interface)
  "The Lisp list held by LIST-INTERFACE, a borrowed IList pointer, with each
element converted by %UNBOX-FRESH."
  (loop for i below (opendaq.low-level:list/get-count list-interface)
        collect (%unbox-fresh (opendaq.low-level:list/get-item-at list-interface i))))

(defun %unbox-daq-dict (dict-interface)
  "The Lisp hash-table held by DICT-INTERFACE, a borrowed IDict pointer, with each
key and value converted by %UNBOX-FRESH."
  (let* ((key-list (opendaq.low-level:dict/get-key-list dict-interface))
         (n (opendaq.low-level:list/get-count key-list))
         (ht (make-hash-table :test 'equal :size n)))
    (unwind-protect
        (loop for i below n
              for key-pointer = (opendaq.low-level:list/get-item-at key-list i)
              for value-pointer = (opendaq.low-level:dict/get dict-interface key-pointer)
              do (setf (gethash (%unbox-fresh key-pointer) ht)
                       (%unbox-fresh value-pointer)))
      (%release-pointer key-list))
    ht))

(defun %unbox-fresh (pointer)
  "UNBOX the object at POINTER, a fresh reference this code owns (a list element or
dict key/value temporary), releasing it once the value is read.  An object with no
Lisp form is instead adopted as a BASE-OBJECT wrapper (owned by the GC) and returned
for the caller to AS-cast.  A null POINTER (an empty getter slot) is NIL."
  (let ((object (wrap pointer 'base-object)))
    (when object
      (multiple-value-bind (kind interface) (%unboxed-kind object)
        (case kind
          ((nil) object)
          (:list (prog1 (%unbox-daq-list interface) (release object)))
          (:dict (prog1 (%unbox-daq-dict interface) (release object)))
          (t (prog1 (%read-boxed-value interface kind) (release object))))))))

(defun unbox (object)
  "Return the natural Lisp value of the openDAQ OBJECT: a boxed scalar yields its
native value (an integer, float, string, boolean, ratio, or complex number), a daq
list yields a Lisp list and a daq dict a Lisp hash-table, with their elements, keys
and values unboxed recursively (an element with no Lisp form -- e.g. a device
sitting in a list -- stays an openDAQ wrapper, for the caller to AS-cast).  The
value's type is discovered from the object itself at runtime, so a generic
BASE-OBJECT needs no cast first:

  (unbox (gethash \"Name\" (parameters event)))  => \"Frequency\"
  (unbox (selection-values property))            => (\"Low\" \"Mid\" \"High\")

A value that is already a native Lisp value is returned unchanged, so UNBOX is
idempotent.  Signals an error for an openDAQ object with no natural Lisp form (a
device, a property object, ...) -- those are what AS / TYPEP are for.  OBJECT is
left intact (its reference is still released by the GC)."
  (if (cl:typep object 'managed-object)
      (multiple-value-bind (kind interface) (%unboxed-kind object)
        (case kind
          ((nil) (error "~S has no natural Lisp form to UNBOX; keep it wrapped and AS it to the openDAQ interface you expect instead." object))
          (:list (%unbox-daq-list interface))
          (:dict (%unbox-daq-dict interface))
          (t (%read-boxed-value interface kind))))
      object))

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

(defun typep (object type)
  "True if OBJECT is a TYPE, i.e. implements the openDAQ interface named by the
class symbol TYPE (e.g. 'CHANNEL, 'SIGNAL, 'FOLDER).  The same interface query
AS performs, but returning a boolean instead of signalling on failure, so it is
safe to ask about any type."
  (opendaq.low-level::%supports-interface-p
   (%require-live-pointer object)
   (%interface-id-getter type)))

(defun component-type (object &optional (candidates *queryable-component-types*))
  "The most-derived interface among CANDIDATES that OBJECT implements, as a
class symbol (e.g. CHANNEL), or NIL if none.  Lets you discover a component's
concrete type before committing to an AS cast."
  (find-if (lambda (type) (typep object type)) candidates))

(defun %list-of (object-list element-type)
  "Convert an openDAQ object-list into a proper Lisp list for the generated
getters, which know their element type statically: a boxed-primitive ELEMENT-TYPE
(e.g. STRING-OBJECT) unboxes each element to its native Lisp value, any other class
symbol casts each element to a wrapper of that class.  A NIL OBJECT-LIST (e.g. from
a getter that returns a null list for the empty case, like
daqCallableInfo_getArguments) is treated as the empty list.  (End-user code wanting
the Lisp view of a daq list it holds should reach for UNBOX instead.)"
  (when object-list
    (loop for i below (count object-list)
          collect (%as-consuming (item-at object-list i) element-type))))

(defun %hashtable-of (dict key-type value-type)
  "Convert an openDAQ dict into a Lisp hash-table for the generated getters, with
each key and value converted per its statically-known KEY-TYPE / VALUE-TYPE exactly
as %LIST-OF converts elements.  A null value (e.g. a descriptor-changed event's
unchanged domain descriptor) maps to NIL."
  (let* ((raw (%require-live-pointer dict))
         (key-list (opendaq.low-level:dict/get-key-list raw))
         (n (opendaq.low-level:list/get-count key-list))
         (ht (make-hash-table :test 'equal :size n)))
    (unwind-protect
        (loop for i below n
              for key-ptr = (opendaq.low-level:list/get-item-at key-list i)
              for val-ptr = (opendaq.low-level:dict/get raw key-ptr)
              for key = (%as-consuming (wrap key-ptr 'base-object) key-type)
              for wrapped-val = (wrap val-ptr 'base-object)
              for val = (and wrapped-val (%as-consuming wrapped-val value-type))
              do (setf (gethash key ht) val))
      (%release-pointer key-list))
    ht))

(defparameter *core-type-classes*
  '((:bool           . boolean-object)
    (:int            . integer-object)
    (:float          . float-object)
    (:string         . string-object)
    (:ratio          . ratio-object)
    (:complex-number . complex-number-object))
  "Maps a DAQ-CORE-TYPE keyword to the boxed-primitive class a value of that type
casts to.  Only the scalar core types appear; the rest (list, dict, struct, object,
proc, func, ...) are not single boxed values and so map to NIL.")

(defun %core-type->class (core-type)
  "The boxed-primitive class a value of CORE-TYPE casts to, or NIL when CORE-TYPE
is not a scalar.  CORE-TYPE is a DAQ-CORE-TYPE keyword (:int, :string, ...), as
returned by VALUE-TYPE; NIL doubles as a \"not a scalar\" predicate for the
property-value conversion below."
  (cdr (assoc core-type *core-type-classes*)))

(defmacro with-batch-property-updates ((&rest objects) &body body)
  "Batch the property writes in BODY into one update per object in OBJECTS.

Each object is any property object (device, channel, function block, ...).
Property values set on it -- or on any of its descendant property objects --
within BODY are staged rather than applied: reads still return the old values
and no OnPropertyValueWrite / OnEndUpdate events fire until the batch closes.
On leaving BODY -- whether normally or via a non-local exit -- each object's
staged values are committed at once, the objects closing in reverse order.
Returns BODY's value.

With a single object this is one atomic update of that object (and its subtree).
Listing several brackets each independently -- convenient for opening and
closing several batches together -- but each object commits its own batch; there
is no atomic commit spanning unrelated objects (for that, bracket a common
ancestor instead).

Wraps BEGIN-UPDATE / END-UPDATE (daqPropertyObject_beginUpdate / _endUpdate)."
  (if (null objects)
      `(progn ,@body)
      (let ((obj (gensym "OBJECT")))
        `(let ((,obj ,(first objects)))
           (begin-update ,obj)
           (unwind-protect
                (with-batch-property-updates ,(rest objects) ,@body)
             (end-update ,obj))))))

;;; ---------------------------------------------------------------------------
;;; Property-value conversion
;;;
;;; PROPERTY-VALUE's raw getter returns a generic BASE-OBJECT, leaving the caller
;;; to recover the useful value with a hand-written (UNBOX (AS value 'class)) (or,
;;; for a callable, a hand-built argument list).  An :AROUND method instead reads
;;; the property's VALUE-TYPE and converts the result to its natural Lisp form, so
;;; that getting a property value mirrors the "plain Lisp values out" contract the
;;; rest of the high-level API follows:
;;;
;;;   * a scalar (BOOL/INT/FLOAT/STRING/RATIO/COMPLEX-NUMBER) is unboxed to its
;;;     native Lisp value -- no AS, no UNBOX needed by the caller;
;;;   * a FUNC or PROC (a callable, not data -- see below) becomes a Lisp function;
;;;   * everything else (OBJECT, STRUCT, LIST, DICT, ...) is left as the wrapper,
;;;     since it has no single scalar value to unbox.
;;;
;;; A property whose value type is FUNC or PROC holds a callable rather than
;;; data.  Instead of handing callers the raw Function/Procedure object -- which
;;; they would have to feed a hand-built argument list and then unbox the result
;;; of -- PROPERTY-VALUE returns an ordinary Lisp function: FUNCALL it with native
;;; Lisp arguments and it boxes them, invokes the openDAQ callable, and returns
;;; the unboxed result.  The property's callable info supplies the declared
;;; argument count (checked before each call) and, for a FUNC, the return type
;;; used to unbox the result; a FUNC whose return type is non-scalar yields the
;;; raw wrapper, and a PROC (no return value) yields NIL.
;;;
;;; FUNC/PROC are recognised from the property's VALUE-TYPE: openDAQ exposes no
;;; interface id for Function or Procedure, so IS-P cannot be used to detect them.
;;; ---------------------------------------------------------------------------

(defun %box-collection (value core-type item-type key-type)
  "Box a Lisp VALUE for an openDAQ argument or container element of CORE-TYPE.  A
:LIST boxes a Lisp list into an OBJECT-LIST; a :DICT boxes a Lisp hash-table into a
DICT.  ITEM-TYPE (and, for a dict, KEY-TYPE) are the element core types the argument
info reports, and box each element/key/value in turn; a nested :LIST / :DICT element,
whose own element types the argument info does not carry, is boxed from the Lisp
value's shape with scalar leaves (pass :UNDEFINED).  A scalar, or a value that is
already a wrapped openDAQ object, is returned unchanged for the :daq-base-object
coercion to box or pass through."
  (flet ((element (v type) (%box-collection v type :undefined :undefined)))
    (case core-type
      (:list (if (listp value)         ; NIL -> empty list; a wrapped object passes through
                 (let ((list (make-instance 'object-list)))
                   (dolist (e value list)
                     (push-back list (element e item-type))))
                 value))
      (:dict (if (hash-table-p value)
                 (let ((dict (make-instance 'dict)))
                   (maphash (lambda (k v) (set dict (element k key-type) (element v item-type))) value)
                   dict)
                 value))
      (t value))))

(defun %box-callable-argument (value info)
  "Box a single Lisp VALUE as the argument an openDAQ callable expects, using its
declared ARGUMENT-INFO: a list argument boxes a Lisp list into an OBJECT-LIST and a
dict argument boxes a Lisp hash-table into a DICT -- each element boxed by the item
(and key) core type the info reports.  Every other type is left for the
:daq-base-object coercion to box (a scalar) or pass through (an already-wrapped
object the caller built by hand).

openDAQ reports the core type of *both* list and dict arguments as :LIST; a dict is
told apart only by carrying a defined key type (getKeyType), so that -- not the core
type alone -- is what selects dict boxing."
  (let ((type (argument-info-type info)))
    (cond ((or (eq type :dict)
               (and (eq type :list) (not (eq (key-type info) :undefined))))
           (%box-collection value :dict (item-type info) (key-type info)))
          ((eq type :list)
           (%box-collection value :list (item-type info) :undefined))
          (t value))))

(defun %callable-params (args arg-infos)
  "Encode ARGS -- each boxed per its declared ARGUMENT-INFO in ARG-INFOS -- as the
params an openDAQ callable expects: NIL for no arguments, the single boxed value for
one, and an OBJECT-LIST for several."
  (case (cl:length args)
    (0 nil)
    ;; A sole NIL argument must be boxed to a Boolean here: left bare it would
    ;; read as the no-arguments encoding (a null params) at the DISPATCH/CALL
    ;; layer.  Inside a list NIL needs no such care -- PUSH-BACK boxes it.
    (1 (or (%box-callable-argument (first args) (first arg-infos))
           (make-instance 'boolean-object :value nil)))
    (t (let ((list (make-instance 'object-list)))
         (loop for arg in args
               for info in arg-infos
               do (push-back list (%box-callable-argument arg info)))
         list))))

(defun %check-callable-arity (name expected args)
  "Signal an error unless ARGS supplies the EXPECTED number of arguments of the
callable property NAME."
  (let ((got (cl:length args)))
    (unless (= got expected)
      (error "openDAQ callable property ~S expects ~D argument~:P but was called with ~D." name expected got))))

(defun %function-property-caller (value property)
  "A Lisp function wrapping the FUNC-property VALUE (an openDAQ Function).  PROPERTY
supplies the callable info: the argument count is checked before each call, and
the return type selects how the result is unboxed (a non-scalar return type leaves
the raw wrapper)."
  (let* ((info (callable-info property))
         (arg-infos (arguments info))
         (arity (cl:length arg-infos))
         (return-class (%core-type->class (return-type info)))
         (name (name property))
         (function (as value 'function-object)))
    (lambda (&rest args)
      (%check-callable-arity name arity args)
      (let ((result (call function (%callable-params args arg-infos) nil)))
        (if return-class
            (unbox result)
            result)))))

(defun %procedure-property-caller (value property)
  "A Lisp function wrapping the PROC-property VALUE (an openDAQ Procedure).  The
argument count is checked against PROPERTY's callable info before each call; a
procedure has no return value, so the function returns NIL."
  (let* ((info (callable-info property))
         (arg-infos (arguments info))
         (arity (cl:length arg-infos))
         (name (name property))
         (procedure (as value 'procedure)))
    (lambda (&rest args)
      (%check-callable-arity name arity args)
      (dispatch procedure (%callable-params args arg-infos))
      nil)))

(defmethod property-value :around ((object property-object) property-name)
  "Convert the value of PROPERTY-NAME to its natural Lisp form based on the
property's VALUE-TYPE: a scalar value is unboxed to its native Lisp value (so the
caller needs no AS/UNBOX), a FUNC or PROC property yields a Lisp function that
invokes the openDAQ callable (boxing its arguments and unboxing its result), and
any other type (OBJECT, STRUCT, LIST, DICT, ...) is returned as the raw wrapper.
The metadata lookup used to classify the property is skipped silently if it fails,
leaving the normal value getter (and its error reporting) in charge."
  (let* ((prop (ignore-errors (property object property-name)))
         (type (and prop (value-type prop)))
         (scalar-class (%core-type->class type)))
    (cond ((eq type :func) (%function-property-caller (call-next-method) prop))
          ((eq type :proc) (%procedure-property-caller (call-next-method) prop))
          (scalar-class (%unbox-primitive (call-next-method) scalar-class))
          (t (call-next-method)))))

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
;;; C trampolines for Lisp closures
;;;
;;; openDAQ's C callback types (daqEventCall, daqProcCall, daqFuncCall) carry no
;;; user-data argument, and portable CFFI cannot turn a Lisp closure into a bare
;;; C function pointer.  So each closure handed to openDAQ needs its own C
;;; trampoline that knows which closure to call.  A trampoline table COMPILEs
;;; one on demand -- a CFFI:DEFCALLBACK baked with a slot index that routes to
;;; the stored closure -- so any number of distinct closures is supported on any
;;; CFFI-capable Lisp.  Each table holds one callback signature's trampolines;
;;; slots whose closure is dropped (e.g. by REMOVE-HANDLER) return to a free
;;; list, so a stable set of callbacks settles on a stable set of trampolines
;;; (one per concurrently-live closure at the peak).
;;; ---------------------------------------------------------------------------

(defstruct (%trampoline-table (:constructor %make-trampoline-table (compiler)))
  "Routes the C trampolines of one callback signature to their Lisp closures.
COMPILER builds the trampoline foreign pointer for a given slot index; FUNCTIONS
holds each slot's closure (NIL when free), POINTERS its compiled trampoline, and
FREE-SLOTS the indices whose closure was dropped and whose trampoline can be
reused."
  (compiler nil :read-only t)
  (functions (make-array 16 :adjustable t :fill-pointer 0))
  (pointers (make-array 16 :adjustable t :fill-pointer 0))
  (free-slots '()))

(defun %trampoline-closure (table index)
  (aref (%trampoline-table-functions table) index))

(defun %allocate-trampoline (table function)
  "Reserve a slot of TABLE for FUNCTION -- reusing a freed slot or growing the
table by compiling a new trampoline -- and return its foreign pointer and index."
  (let ((index (or (pop (%trampoline-table-free-slots table))
                   (let ((new-index (fill-pointer (%trampoline-table-functions table))))
                     (vector-push-extend nil (%trampoline-table-functions table))
                     (vector-push-extend (funcall (%trampoline-table-compiler table) new-index)
                                         (%trampoline-table-pointers table))
                     new-index))))
    (setf (aref (%trampoline-table-functions table) index) function)
    (cl:values (aref (%trampoline-table-pointers table) index) index)))

(defun %free-trampoline (table index)
  "Return slot INDEX of TABLE to the free list, dropping its closure; the
compiled trampoline stays behind for the next allocation to reuse."
  (setf (aref (%trampoline-table-functions table) index) nil)
  (push index (%trampoline-table-free-slots table))
  nil)

;;; ---------------------------------------------------------------------------
;;; Event handlers from Lisp functions
;;;
;;; Refcounts take care of themselves: the C binding add-refs sender and args
;;; before calling us (handing the callback ownership of one reference to each),
;;; and wrapping them as managed objects lets the GC finalizers release exactly
;;; those references -- so a handler function never has to release anything.
;;; ---------------------------------------------------------------------------

(defvar *event-trampolines*
  (%make-trampoline-table
   (lambda (index)
     (let ((name (gensym "EVENT-CALLBACK")))
       (funcall (compile nil `(lambda ()
                                (cffi:defcallback ,name :void ((sender :pointer) (args :pointer))
                                  (%dispatch-event-callback ,index sender args)))))
       (cffi:get-callback name))))
  "Trampolines for daqEventCall: `void (BaseObject* sender, BaseObject* args)'.")

(defvar *event-handler-callback-indices*
  (trivial-garbage:make-weak-hash-table :weakness :key :test 'eq)
  "Maps a function-backed EVENT-HANDLER to its slot, so REMOVE-HANDLER can free it.")

(defun %dispatch-event-callback (index sender args)
  (let ((function (%trampoline-closure *event-trampolines* index)))
    (when function
      (funcall function (wrap sender 'base-object) (wrap args 'base-object)))))

(defmethod initialize-instance :around ((handler event-handler) &rest initargs &key function &allow-other-keys)
  "Let :FUNCTION be a Lisp function of (SENDER ARGS), called when the event fires,
as an alternative to the raw :CALL foreign pointer.  SENDER and ARGS arrive as
managed objects whose references the GC releases, so the function need not clean
anything up; cast ARGS with AS for typed event args (e.g. to CORE-EVENT-ARGS)."
  (if function
      (multiple-value-bind (pointer index) (%allocate-trampoline *event-trampolines* function)
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
      (%free-trampoline *event-trampolines* index)
      (remhash handler *event-handler-callback-indices*))))

;;; ---------------------------------------------------------------------------
;;; Procedures and functions from Lisp closures
;;;
;;; (make-instance 'procedure :value fn) and (make-instance 'function-object
;;; :value fn) accept a Lisp function as an alternative to the raw daqProcCall /
;;; daqFuncCall foreign pointer the C API takes.  openDAQ then invokes FN
;;; whenever the callable is dispatched -- from Lisp or from native code (a
;;; function property's value, a custom search filter, ...).
;;;
;;; The closure is APPLYed to the decoded params (see %CALLABLE-ARGS), so it
;;; declares its natural lambda list; a function's return value is boxed like a
;;; :daq-base-object argument and its reference handed to the native caller.
;;; Unlike the event callback, nothing is add-ref'd for us: the native side
;;; passes params BORROWED and expects a daqErrCode back.  A condition the
;;; closure signals must not unwind across the C boundary, so it is caught and
;;; reported as OPENDAQ_ERR_GENERALERROR, which the call site then surfaces as
;;; an OPENDAQ-ERROR.
;;;
;;; Lifetime: openDAQ offers no destruction hook for a callable, so -- unlike an
;;; event handler's slot, which REMOVE-HANDLER frees -- a closure-backed
;;; procedure or function pins its closure and trampoline slot for the life of
;;; the image (the native object, e.g. one stored as a property value, can
;;; outlive every Lisp reference to it).
;;; ---------------------------------------------------------------------------

(defconstant +opendaq-success+ 0)

(defconstant +opendaq-err-general-error+ #x80000014
  "OPENDAQ_ERR_GENERALERROR: reported to the native caller when a Lisp-implemented
callable signals a condition.")

(defun %callable-args (params)
  "Decode PARAMS -- the borrowed daqBaseObject* openDAQ hands a callable's
implementation -- into the list of Lisp arguments to APPLY the closure to,
inverting %CALLABLE-PARAMS' encoding: a null params means no arguments, a daq
list one argument per element, anything else the single argument.  Each argument
converts by UNBOX's rules -- scalars and containers to native Lisp values,
anything else left wrapped for the closure to AS-cast.  (The encoding is
openDAQ's own convention, so a single argument that IS a daq list still arrives
unpacked into several.)"
  (if (cffi:null-pointer-p params)
      '()
      (progn
        ;; PARAMS is borrowed: add the reference the wrapper's GC finalizer
        ;; releases.
        (opendaq.low-level:unknown/add-ref params)
        (let ((object (wrap params 'base-object)))
          (multiple-value-bind (kind interface) (%unboxed-kind object)
            (case kind
              (:list (%unbox-daq-list interface))
              ((nil) (cl:list object))
              (:dict (cl:list (%unbox-daq-dict interface)))
              (t (cl:list (%read-boxed-value interface kind)))))))))

(defun %box-transferring-reference (value)
  "Box VALUE -- what a closure-backed function returned -- into a daq object
pointer whose single reference is transferred to the native caller: an openDAQ
wrapper is add-ref'd and its pointer returned; a Lisp list or hash-table boxes
to a daq list/dict; anything else boxes exactly as a :daq-base-object argument
would (NIL to Boolean false).  Signals an error for a value openDAQ cannot box."
  (cond ((cl:typep value 'managed-object)
         (let ((raw (%require-live-pointer value)))
           (opendaq.low-level:unknown/add-ref raw)
           raw))
        ((and value (listp value))
         (%box-transferring-reference (%box-collection value :list :undefined :undefined)))
        ((hash-table-p value)
         (%box-transferring-reference (%box-collection value :dict :undefined :undefined)))
        (t
         (multiple-value-bind (pointer cleanup) (%coerce-argument value :daq-base-object)
           ;; A fresh box arrives holding the one reference CLEANUP would
           ;; release; skipping the cleanup is exactly the transfer.
           (declare (ignore cleanup))
           (if (cffi:pointerp pointer)
               pointer
               (error "Cannot box ~S as an openDAQ object." value))))))

(defvar *procedure-trampolines*
  (%make-trampoline-table
   (lambda (index)
     (let ((name (gensym "PROCEDURE-CALLBACK")))
       (funcall (compile nil `(lambda ()
                                (cffi:defcallback ,name opendaq.low-level::daq-err-code
                                    ((params :pointer))
                                  (%dispatch-procedure-callback ,index params)))))
       (cffi:get-callback name))))
  "Trampolines for daqProcCall: `daqErrCode (BaseObject* params)'.")

(defvar *function-trampolines*
  (%make-trampoline-table
   (lambda (index)
     (let ((name (gensym "FUNCTION-CALLBACK")))
       (funcall (compile nil `(lambda ()
                                (cffi:defcallback ,name opendaq.low-level::daq-err-code
                                    ((params :pointer) (result :pointer))
                                  (%dispatch-function-callback ,index params result)))))
       (cffi:get-callback name))))
  "Trampolines for daqFuncCall: `daqErrCode (BaseObject* params, BaseObject** result)'.")

(defun %dispatch-procedure-callback (index params)
  (handler-case
      (progn
        (apply (%trampoline-closure *procedure-trampolines* index) (%callable-args params))
        +opendaq-success+)
    (serious-condition () +opendaq-err-general-error+)))

(defun %dispatch-function-callback (index params result)
  (handler-case
      (let ((value (apply (%trampoline-closure *function-trampolines* index)
                          (%callable-args params))))
        (setf (cffi:mem-ref result :pointer) (%box-transferring-reference value))
        +opendaq-success+)
    (serious-condition () +opendaq-err-general-error+)))

(defmethod initialize-instance :around ((object procedure) &rest initargs &key value &allow-other-keys)
  "Let :VALUE be a Lisp function, invoked with the decoded params (see
%CALLABLE-ARGS) each time the procedure is dispatched, as an alternative to the
raw daqProcCall foreign pointer."
  (if (functionp value)
      (apply #'call-next-method object
             :value (%allocate-trampoline *procedure-trampolines* value)
             initargs)
      (call-next-method)))

(defmethod initialize-instance :around ((object function-object) &rest initargs &key value &allow-other-keys)
  "Let :VALUE be a Lisp function, invoked with the decoded params (see
%CALLABLE-ARGS) each time the function is called and whose return value becomes
the call's boxed result, as an alternative to the raw daqFuncCall foreign
pointer."
  (if (functionp value)
      (apply #'call-next-method object
             :value (%allocate-trampoline *function-trampolines* value)
             initargs)
      (call-next-method)))

(defmethod dispatch :around ((object procedure) params)
  "A NIL params means \"no arguments\" -- openDAQ's null params, matching
%CALLABLE-PARAMS' encoding -- rather than the Boolean false the :daq-base-object
boxing would otherwise make of it.  Pass a BOOLEAN-OBJECT to give a procedure a
single false argument."
  (call-next-method object (if (null params) (cffi:null-pointer) params)))

(defmethod call :around ((object function-object) params result)
  "As with DISPATCH: a NIL params encodes \"no arguments\" (a null params), not a
single Boolean false argument."
  (call-next-method object (if (null params) (cffi:null-pointer) params) result))
