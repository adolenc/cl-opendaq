(ql:quickload :opendaq :silent t)


(defparameter *instance*
  (let ((builder (make-instance 'daq:instance-builder)))
    (setf (daq:module-path builder) (daq:native-library-directory))  ; the bundled modules (use setf to override opendaq's default cwd)
    ; (daq:add-module-path builder "/path/to/your/modules")         ; your own modules folder
    (make-instance 'daq:instance :builder builder)))
(daq:add-device *instance* "daqref://device0")

(defparameter *channel* (daq:as (daq:find-component *instance* "Dev/RefDev0/IO/AI/RefCh0") 'daq:channel))
(setf (daq:property-value *channel* "Amplitude") 5.0 
      (daq:property-value *channel* "DC")        1.0)

(defparameter *statistics* (daq:add-function-block *instance* "RefFBModuleStatistics" nil))
(setf (daq:property-value *statistics* "BlockSize") 100)

(let ((port (first (daq:input-ports *statistics*)))
      (signal (first (daq:signals *channel*))))
  (daq:connect port signal))

(let* ((signals (daq:signals *statistics*))
       (avg (find "avg" signals :key #'daq:name :test #'string=))
       (rms (find "rms" signals :key #'daq:name :test #'string=))
       (reader (make-instance 'daq:multi-reader :signals (list avg rms))))
  ;; The first reads may return nothing while the block waits for a complete
  ;; input descriptor (multireader by default doesn't skip events), so retry until samples arrive.
  (loop for attempt below 20 do
    (let ((values (daq:read reader 5 :timeout-ms 1000)))
      (when (plusp (length (first values)))
        (format t "~10@A~12@A~%" "avg" "rms")
        (loop for a across (first values)
              for r across (second values)
              do (format t "~10,4F~12,4F~%" a r))
        (return)))
    finally (format t "Statistics block produced no samples in time.~%")))
