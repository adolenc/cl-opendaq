(in-package #:opendaq.tests)

(in-suite smoke-suite)

(test opendaq-error-report-includes-code-name-and-message
  (let* ((err (make-condition 'opendaq:opendaq-error
                              :code #x8000000A
                              :operation "addDevice"
                              :message "Failed to create device from connection string 'daqref://device1'"))
         (report (with-output-to-string (s)
                   (princ err s))))
    (is (search "OPENDAQ_ERR_ALREADYEXISTS" report)
        "Error report should include the code name, not 'an unknown error'.")
    (is (search "Failed to create device" report)
        "Error report should include the descriptive message.")))

(test duplicating-device-reports-readable-error
  (locally (declare (optimize (debug 3)))
    (let* ((instance (make-instance 'daq:instance))
           (root-device (daq:root-device instance))
           (dev (daq:add-device root-device "daqref://device1"))
           caught)
      (declare (ignore dev))
      (handler-case
          (daq:add-device root-device "daqref://device1")
        (opendaq:opendaq-error (c)
          (setf caught c)))
      (is (not (null caught)) "Adding the same device twice should signal an error.")
      (let ((msg (opendaq:opendaq-error-message caught)))
        (is (stringp msg) "The error should have a non-nil message.")
        (is (plusp (length msg)) "The error message should not be empty.")))))
