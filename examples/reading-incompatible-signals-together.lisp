(ql:quickload '(:opendaq :local-time) :silent t)


;;; Read two linear-domain signals and one explicit-domain signal at the same
;;; time, and line all three up on a shared wall-clock time axis.
;;;
;;;   * The two linear signals are the reference device's analog channels.  Their
;;;     domain is an implicit linear rule (tick = start + n*delta), and we read
;;;     them together with a MULTI-READER, which hands back one common domain.
;;;
;;;   * The explicit-domain signal is the block average of channel 0 produced by a
;;;     Statistics function block with DomainSignalType = Explicit: instead of a
;;;     linear rule it emits, per average, the actual tick of the first raw sample
;;;     in its block.  We read it with a STREAM-READER.
;;;
;;; All three ride the same device clock, so every average's explicit tick equals
;;; one of the channel ticks -- convert both to timestamps and the columns line up
;;; exactly, one average every BLOCK-SIZE channel samples.

(defparameter *sample-rate* 100.0)                               ; Hz, device-wide
(defparameter *block-size* 10)                                   ; channel samples per average
(defparameter *window* 30)                                       ; channel samples to display

(defun timestamp->string (timestamp)
  "Render TIMESTAMP as a readable time-of-day, e.g. \"21:05:28.400000\"."
  (local-time:format-timestring
    nil timestamp
    :format '((:hour 2) ":" (:min 2) ":" (:sec 2) "." (:usec 6))
    :timezone local-time:+utc-zone+))


(defparameter *instance* (make-instance 'daq:instance))
(defparameter *device* (daq:add-device *instance* "daqref://device0"))
(setf (daq:property-value *device* "GlobalSampleRate") *sample-rate*)

(defparameter *ch0* (daq:as (daq:find-component *instance* "Dev/RefDev0/IO/AI/RefCh0") 'daq:channel))
(defparameter *ch1* (daq:as (daq:find-component *instance* "Dev/RefDev0/IO/AI/RefCh1") 'daq:channel))
(setf (daq:property-value *ch0* "Frequency") 5.0
      (daq:property-value *ch1* "Frequency") 10.0)
(defparameter *ch0-signal* (first (daq:signals *ch0*)))
(defparameter *ch1-signal* (first (daq:signals *ch1*)))

;; Statistics block averaging channel 0 in blocks of *BLOCK-SIZE* samples.
;; DomainSignalType = 1 (Explicit) makes its output domain an explicit list of
;; ticks -- one tick per average, taken from the block's first raw sample.
(defparameter *stats-fb* (daq:add-function-block *instance* "RefFBModuleStatistics" nil))
(setf (daq:property-value *stats-fb* "BlockSize") *block-size*
      (daq:property-value *stats-fb* "DomainSignalType") 1)
(daq:connect (first (daq:input-ports *stats-fb*)) *ch0-signal*)
(defparameter *avg-signal* (first (daq:signals *stats-fb*)))

(defparameter *multi-reader* (make-instance 'daq:multi-reader :signals (list *ch0-signal* *ch1-signal*)))
(defparameter *stream-reader* (make-instance 'daq:stream-reader :signal *avg-signal*))


;; Let both streams warm up so their queues overlap in time.
(sleep 1)

(defparameter *chunk* 5)                                         ; samples per read

;; Fill the display window with many small reads rather than one big one,
;; interleaving the two readers so they advance together.  Channel samples are
;; collected until the window is full; averages go into a tick->value table and
;; keep being read until they have caught up to the end of the window -- an
;; average only appears once its whole block of channel samples has arrived.
(let ((rows (make-array 0 :adjustable t :fill-pointer 0))        ; (tick v0 v1) per channel sample
      (avg-by-tick (make-hash-table))
      (newest-avg-tick -1))
  (loop repeat 200
        for window-full = (>= (fill-pointer rows) *window*)
        until (and window-full (>= newest-avg-tick (first (aref rows (1- *window*)))))
        do (unless window-full
             (multiple-value-bind (values domain) (daq:read-with-domain *multi-reader* *chunk* :timeout-ms 1000)
               (loop for tick across (first domain)
                     for v0 across (first values)
                     for v1 across (second values)
                     do (vector-push-extend (list tick v0 v1) rows))))
           (multiple-value-bind (avgs ticks) (daq:read-with-domain *stream-reader* *chunk* :timeout-ms 1000)
             (loop for avg across avgs
                   for tick across ticks
                   do (setf (gethash tick avg-by-tick) avg
                            newest-avg-tick (max newest-avg-tick tick)))))

  ;; The multi-reader only knows its common domain once it has read, so build the
  ;; tick->time converter now.
  (let ((channel-time (daq:domain-time-converter *multi-reader*)))
    (format t "~14A~14@A~14@A~16@A~%" "time" "channel 0" "channel 1" "avg(channel 0)")
    (dotimes (i *window*)
      (destructuring-bind (tick v0 v1) (aref rows i)
        (let ((avg (gethash tick avg-by-tick)))
          (format t "~14A~14,4F~14,4F~16@A~%"
                  (timestamp->string (funcall channel-time tick))
                  v0 v1
                  (if avg (format nil "~,4F" avg) "")))))))
