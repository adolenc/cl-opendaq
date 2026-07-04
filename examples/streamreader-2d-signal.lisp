(ql:quickload :opendaq :silent t)


(defparameter *instance* (make-instance 'daq:instance))
(daq:add-device *instance* "daqref://device0")

(defparameter *channel* (daq:as (daq:find-component *instance* "Dev/RefDev0/IO/AI/RefCh0") 'daq:channel))
(setf (daq:property-value *channel* "Waveform")       0       ; 0 = Sine
      (daq:property-value *channel* "Frequency")      125.0
      (daq:property-value *channel* "Amplitude")      5.0
      (daq:property-value *channel* "NoiseAmplitude") 0.1)

(defparameter *fft-fb* (daq:add-function-block *instance* "RefFBModuleFFT" nil))
(setf (daq:property-value *fft-fb* "BlockSize") 16)
(daq:connect (first (daq:input-ports *fft-fb*)) (first (daq:signals *channel*)))
(defparameter *signal* (first (daq:signals *fft-fb*)))

;; Wait for the block to publish its output descriptor, then read the frequency
;; axis off the value descriptor's single dimension.
(sleep 1)
(defparameter *dimension* (first (daq:dimensions (daq:descriptor *signal*))))
(defparameter *axis* (map 'vector #'daq:unbox (daq:labels *dimension*)))

;; Read 5 samples.  Each sample is a full spectrum, so DAQ:READ returns a
;; (samples x bins) matrix; retry until 5 rows have arrived (the first reads may
;; come back short while the stream warms up).
(defparameter *reader* (make-instance 'daq:stream-reader :signal *signal*))
(defparameter *samples*
  (loop for attempt below 50
        for spectra = (daq:read *reader* 5 :timeout-ms 1000)
        when (= (array-dimension spectra 0) 5) return spectra
        finally (return spectra)))

;; Print the axis down the rows and one column of amplitudes per sample.  The
;; 125 Hz tone dominates a single bin (~5, our amplitude) while noise fills the
;; rest with small values.  The reference block labels its bins one step
;; (31.25 Hz) below the true bin centre, so the tone lands in the 93.75 Hz row.
(format t "~A spectrum, ~D bins, ~A~%~%" (daq:name *dimension*) (length *axis*) (daq:symbol (daq:unit *dimension*)))
(format t "~12@A~{~14@A~}~%" "freq (Hz)" (loop for i below (array-dimension *samples* 0) collect (format nil "sample ~D" (1+ i))))
(dotimes (bin (length *axis*))
  (format t "~12,2F~{~14,4F~}~%"
          (aref *axis* bin)
          (loop for sample below (array-dimension *samples* 0) collect (aref *samples* sample bin))))
