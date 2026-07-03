(ql:quickload :opendaq :silent t)


(defparameter *instance* (make-instance 'daq:instance))
(defparameter *device* (daq:add-device *instance* "daqref://device0"))
(defparameter *ch0* (first (daq:channels *device*)))
(defparameter *ch1* (second (daq:channels *device*)))

(defun show-settings (label channel)
  (format t "~A ~A:  Amplitude=~A  Frequency=~A  Waveform=~A~%"
          label
          (daq:name channel)
          (daq:property-value channel "Amplitude")
          (daq:property-value channel "Frequency")
          (daq:property-value channel "Waveform")))


(show-settings "Before:          " *ch0*)
(show-settings "Before:          " *ch1*)

(daq:with-batch-property-updates (*ch0* *ch1*)
  (setf (daq:property-value *ch0* "Amplitude") 2.5d0)
  (setf (daq:property-value *ch0* "Frequency") 25.0d0)
  (setf (daq:property-value *ch0* "Waveform") 1)
  (setf (daq:property-value *ch1* "Amplitude") 4.0d0)
  (setf (daq:property-value *ch1* "Frequency") 50.0d0)
  (setf (daq:property-value *ch1* "Waveform") 2)
  ;; Still inside the batch: the writes above are staged but not yet applied.
  (show-settings "During (staged): " *ch0*)
  (show-settings "During (staged): " *ch1*))

(show-settings "After the batch: " *ch0*)
(show-settings "After the batch: " *ch1*)
