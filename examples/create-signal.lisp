(ql:quickload '(:opendaq :local-time) :silent t)


;;; Build a signal by hand and read it back with wall-clock timestamps.
;;;
;;; The trick for making the domain timestamps line up with the PC clock is NOT
;;; to move the origin to "now": the origin stays pinned at the Unix epoch, and
;;; the current time is carried entirely by the integer domain *ticks*.  With a
;;; tick resolution of 1/1000 s (one tick = one millisecond) a sample's absolute
;;; time is  origin + tick/1000 s, so a tick equal to the current Unix time in
;;; milliseconds reads back as the current wall-clock time.  Spacing the ticks
;;; 200 apart (200 ms) then yields exactly 5 samples per second.

(defparameter *samples-per-second* 5)
(defparameter *tick-resolution* 1/1000)                          ; seconds per tick (1 ms)
(defparameter *ticks-per-sample* (/ 1 (* *samples-per-second* *tick-resolution*)))              ; 200 ticks = 200 ms

(defun timestamp->string (timestamp)
  "Render TIMESTAMP as a readable time-of-day, e.g. \"21:05:28.400000\"."
  (local-time:format-timestring
    nil timestamp
    :format '((:hour 2) ":" (:min 2) ":" (:sec 2) "." (:usec 6))
    :timezone local-time:+utc-zone+))

(defun now-ticks ()
  "The current PC time as an integer tick count (milliseconds since the Unix
epoch, i.e. since the domain origin)."
  (let ((now (local-time:now)))
    (+ (* 1000 (local-time:timestamp-to-unix now))
       (floor (local-time:nsec-of now) 1000000))))


(defparameter *instance* (make-instance 'daq:instance))

(defparameter *domain-descriptor*
  (let ((builder (make-instance 'daq:data-descriptor-builder)))
    (setf (daq:sample-type builder) :int64
          (daq:name builder) "time"
          ;; Origin stays at the epoch; the wall-clock time lives in the ticks.
          (daq:origin builder) "1970-01-01T00:00:00Z"
          (daq:tick-resolution builder) *tick-resolution*
          (daq:unit builder) (make-instance 'daq:unit :id -1 :symbol "s" :name "second" :quantity "time")
          (daq:rule builder) (make-instance 'daq:data-rule/linear :delta *ticks-per-sample* :start 0))
    (daq:build builder)))
(defparameter *value-descriptor*
  (let ((builder (make-instance 'daq:data-descriptor-builder)))
    (setf (daq:sample-type builder) :float64
          (daq:name builder) "values")
    (daq:build builder)))
(defparameter *domain-signal* (make-instance 'daq:signal-config :context (daq:context *instance*) :parent nil :local-id "time" :class-name nil))
(setf (daq:descriptor *domain-signal*) *domain-descriptor*)
(defparameter *signal* (make-instance 'daq:signal-config :context (daq:context *instance*) :parent nil :local-id "values" :class-name nil))
(setf (daq:descriptor *signal*) *value-descriptor*
      (daq:domain-signal *signal*) *domain-signal*)

(defparameter *reader* (make-instance 'daq:stream-reader :signal *signal* :timeout-type :any))

(defun send-chunk (offset samples)
  "Send SAMPLES (a vector of reals) as one packet whose implicit domain ticks
start at OFFSET and advance by *TICKS-PER-SAMPLE* per sample."
  (let* ((count (length samples))
         (domain-packet (make-instance 'daq:data-packet :descriptor *domain-descriptor* :sample-count count :offset offset))
         (packet (make-instance 'daq:data-packet/with-domain :domain-packet domain-packet :descriptor *value-descriptor* :sample-count count :offset 0)))
    (setf (daq:data packet) samples)
    (daq:send-packet *signal* packet)))


;;; Stream a few seconds of a 5 Hz signal in real time.  Each one-second batch is
;;; one packet of 5 samples; the ticks stay contiguous across batches (batch k
;;; starts at start-tick + k*1000 ms), so the whole run is an unbroken 5 Hz stream
;;; anchored to when the script started.
(let* ((batches 3)
       (start-tick (now-ticks))
       (to-timestamp (daq:domain-time-converter *signal*)))
  (format t "Streaming ~D samples/second, starting at ~A~%"
          *samples-per-second* (timestamp->string (funcall to-timestamp start-tick)))
  (dotimes (batch batches)
    (let* ((base-sample (* batch *samples-per-second*))
           (offset (+ start-tick (* base-sample *ticks-per-sample*)))
           (samples (coerce (loop for i below *samples-per-second*
                                  for n = (+ base-sample i)
                                  collect (coerce (sin (* 2 pi (/ n 25.0))) 'double-float))
                            'vector)))
      (send-chunk offset samples))
    (multiple-value-bind (values ticks) (daq:read-with-domain *reader* 100 :timeout-ms 1000)
      (loop for value across values
            for tick across ticks
            do (format t "  ~A  ->  ~,4F~%"
                       (timestamp->string (funcall to-timestamp tick))
                       value)))
    (sleep 1)))
