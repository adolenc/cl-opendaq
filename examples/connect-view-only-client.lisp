(ql:quickload :opendaq :silent t)


(defparameter *instance* (make-instance 'daq:instance))

(defun first-writable-property-name (object)
  "Name of OBJECT's first visible, non-read-only, non-callable property, or NIL.
Used to probe whether the connection actually refuses writes."
  (loop for prop in (daq:visible-properties object)
        unless (or (daq:read-only prop)
                   (member (daq:value-type prop) '(:func :proc)))
          do (return (daq:name prop))))


(defparameter *config* (daq:create-default-add-device-config *instance*))

(let* ((general (daq:as (daq:property-value *config* "General") 'daq:property-object))
       (client-type (daq:property general "ClientType"))
       (options (daq:unbox (daq:selection-values client-type))))
  (format t "Available ClientType options:~%")
  (loop for key in (sort (loop for k being the hash-keys of options collect k) #'<)
        do (format t "  ~A = ~A~%" key (gethash key options))))

(setf (daq:property-value *config* "General.ClientType") 2) ; 2 = view-only
(defparameter *connection-string* (or (uiop:getenv "OPENDAQ_DEVICE") "daq.nd://127.0.0.1"))

(handler-case
    (let* ((device (daq:add-device *instance* *connection-string* *config*)))
      (format t "Connected to ~A as a view-only client.~%" (daq:name device))
      (format t "Visible signals: ~D~%" (length (daq:signals-recursive device)))
      (let ((prop (first-writable-property-name device)))
        (if prop
            (handler-case
                (progn
                  (setf (daq:property-value device prop)
                        (daq:property-value device prop))
                  (format t "Unexpected: writing ~S was allowed.~%" prop))
              (error (e)
                (format t "Write to ~S refused, as expected for view-only: ~A~%" prop e)))
            (format t "Device exposes no writable property to probe.~%"))))
  (error (e)
    (format t "Could not connect to ~A: ~A~%" *connection-string* e)
    (format t "Start an openDAQ device/simulator there, or set OPENDAQ_DEVICE.~%")))
