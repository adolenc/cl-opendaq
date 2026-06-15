(defpackage #:opendaq.low-level
  (:use #:cl)
  (:intern #:clear-error-info
           #:ensure-opendaq-loaded
           #:healthcheck
           #:native-library-directory
           #:opendaq-error
           #:opendaq-error-code
           #:opendaq-error-message
           #:opendaq-error-operation)
  (:export #:make-daq-string
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
           #:denominator
           #:read)
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
