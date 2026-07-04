(ql:quickload :opendaq :silent t)

;;; A reader is invalidated when its signal's descriptor changes to a sample type
;;; the reader cannot convert to its configured read type. The reader needs to
;;; be recovered by creating a new one via /from-existing constructor.

(defparameter *instance* (make-instance 'daq:instance))
(daq:add-device *instance* "daqref://device0")
(defparameter *channel* (daq:as (daq:find-component *instance* "Dev/RefDev0/IO/AI/RefCh0") 'daq:channel))
(setf (daq:property-value *channel* "Waveform")       0
      (daq:property-value *channel* "Amplitude")      0.0
      (daq:property-value *channel* "DC")             2.0
      (daq:property-value *channel* "NoiseAmplitude") 0.0)

;; Average the channel in blocks of 10 samples.  DomainSignalType starts at
;; 0 = Implicit: the output domain is int64 ticks under a linear rule.
(defparameter *statistics-fb* (daq:add-function-block *instance* "RefFBModuleStatistics" nil))
(daq:connect (first (daq:input-ports *statistics-fb*)) (first (daq:signals *channel*)))
(defparameter *avg-signal* (first (daq:signals *statistics-fb*)))

(defun show-averages (reader &key (count 4))
  "Read COUNT averages with their domain values and print them (retrying while
the stream warms up)."
  (loop for attempt below 50
        do (multiple-value-bind (averages ticks) (daq:read-with-domain reader count :timeout-ms 1000)
             (when (plusp (length averages))
               (loop for average across averages
                     for tick across ticks
                     do (format t "  tick ~A  ->  avg ~,3F~%" tick average))
               (return)))
        finally (error "The statistics stream produced no averages.")))

;; Phase 1: read averages with the domain ticks as doubles -- fine while the
;; domain is int64, which converts to float64.
(defparameter *reader* (make-instance 'daq:stream-reader :signal *avg-signal* :domain-read-type :float64))
(format t "implicit int64 domain, read as float64:~%")
(show-averages *reader*)

;; Phase 2: switch the output domain to 2 = ExplicitRange -- each average's
;; domain value becomes the RangeInt64 tick range of the block it covers, and
;; RangeInt64 has no conversion to float64.  The change reaches the reader as a
;; descriptor-changed event in its packet queue; READ hands over the samples
;; queued before the change, then hits the event and signals READER-INVALIDATED.
(setf (daq:property-value *statistics-fb* "DomainSignalType") 2)
(defparameter *recovered*
  (handler-case
      (loop repeat 50
            do (daq:read-with-domain *reader* 100 :timeout-ms 200)
            finally (error "Expected the domain change to invalidate the reader."))
    (daq:reader-invalidated (condition)
      (format t "~A~%" condition)
      (make-instance 'daq:stream-reader/from-existing
                     :invalidated-reader (daq:reader-invalidated-reader condition)
                     :value-read-type :float64
                     :domain-read-type :int64))))

(format t "explicit RangeInt64 domain, read as int64 range starts:~%")
(show-averages *recovered*)
