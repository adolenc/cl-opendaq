(defpackage #:opendaq
  (:nicknames #:daq)
  (:use #:cl)
  (:export #:clear-error-info
           #:ensure-opendaq-loaded
           #:make-daq-string
           #:native-library-directory
           #:opendaq-error
           #:opendaq-error-code
           #:opendaq-error-operation
           #:with-daq-objects))
