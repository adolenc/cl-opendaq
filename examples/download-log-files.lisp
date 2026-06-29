(ql:quickload :opendaq :silent t)

;; Download a device's log files: enumerate them with DEVICE/getLogFileInfos and
;; pull each one's contents with DEVICE/getLog.  On a real (often remote) device
;; the logs already exist; the bundled reference device only produces one when you
;; ask it to, so this example first sets that up:
;;
;;   * give the instance a file logger sink, so openDAQ actually writes a log file;
;;   * add the device with EnableLogging = true and LoggingPath pointing at that
;;     same file -- that is the file the reference device reports and serves.
;;
;; LOG-FILE-INFOS / LOG then behave exactly as they would against a remote device.

(defparameter *work-dir* (ensure-directories-exist (merge-pathnames "cl-opendaq-log-example/" (uiop:temporary-directory))))
(defparameter *device-log* (namestring (merge-pathnames "ref_device_simulator.log" *work-dir*)))
(defparameter *downloads* (ensure-directories-exist (merge-pathnames "downloads/" *work-dir*)))

;; Start from a clean log so the reported size reflects only this run.
(uiop:delete-file-if-exists *device-log*)

(defparameter *instance*
  (let ((builder (make-instance 'daq:instance-builder)))
    (setf (daq:module-path builder) (daq:native-library-directory))   ; find the bundled modules
    (daq:add-logger-sink builder (make-instance 'daq:logger-sink :file-name *device-log*))
    (make-instance 'daq:instance :builder builder)))

;; The reference device reads these two properties from its add-device config.
(defparameter *config* (make-instance 'daq:property-object))
(daq:add-property *config* (make-instance 'daq:property/bool   :name "EnableLogging" :default-value t          :visible t))
(daq:add-property *config* (make-instance 'daq:property/string :name "LoggingPath"   :default-value *device-log* :visible t))

(defparameter *device* (daq:add-device *instance* "daqref://device0" *config*))

;; Flush the logger so everything buffered so far is actually on disk before we read it.
(daq:flush (daq:logger (daq:context *instance*)))

(defun download-log (id destination)
  "Retrieve the full contents of log file ID from *DEVICE* and write them to
DESTINATION, returning the number of characters written.  Passing no size/offset
to LOG (defaults -1 and 0) fetches the whole file in one call."
  (let ((content (daq:log *device* id)))
    (with-open-file (out destination :direction :output :external-format :utf-8
                                     :if-exists :supersede :if-does-not-exist :create)
      (write-string content out))
    (length content)))

(let ((infos (daq:log-file-infos *device*)))
  (if (null infos)
      (format t "Device exposes no log files.~%")
      (progn
        (format t "Device exposes ~D log file~:P:~%~%" (length infos))
        (dolist (info infos)
          (let ((dest (merge-pathnames (daq:name info) *downloads*)))
            (format t "• ~A~%" (daq:name info))
            (format t "    id:            ~A~%" (daq:id info))
            (format t "    size:          ~A bytes~%" (daq:size info))
            (format t "    encoding:      ~A~%" (daq:encoding info))
            (format t "    last-modified: ~A~%" (daq:last-modified info))
            (format t "    preview:       ~S~%" (daq:log *device* (daq:id info) 60 0))   ; size/offset let you fetch just part of a file; here, a short head preview.
            (format t "    downloaded ~D chars -> ~A~%~%" (download-log (daq:id info) dest) dest))))))
