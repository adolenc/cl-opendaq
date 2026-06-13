(defpackage #:opendaq.low-level
  (:use #:cl)
  (:export #:clear-error-info
           #:healthcheck
           #:ensure-opendaq-loaded
           #:make-daq-string
           #:native-library-directory
           #:opendaq-error
           #:opendaq-error-code
           #:opendaq-error-message
           #:opendaq-error-operation
           #:with-daq-objects))

(defpackage #:opendaq.high-level
  (:nicknames #:daq #:opendaq)
  (:use #:cl)
  (:import-from #:opendaq.low-level
                #:clear-error-info
                #:ensure-opendaq-loaded
                #:healthcheck
                #:native-library-directory
                #:opendaq-error
                #:opendaq-error-code
                #:opendaq-error-message
                #:opendaq-error-operation)
  (:shadow #:ratio
           #:numerator
           #:denominator)
  (:export #:as
           #:as-list
           #:clear-error-info
           #:ensure-opendaq-loaded
           #:healthcheck
           #:native-library-directory
           #:opendaq-error
           #:opendaq-error-code
           #:opendaq-error-message
           #:opendaq-error-operation))
