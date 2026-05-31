(defpackage #:opendaq
  (:nicknames #:daq.ll)
  (:use #:cl)
  (:export #:clear-error-info
           #:healthcheck
           #:ensure-opendaq-loaded
           #:make-daq-string
           #:native-library-directory
           #:opendaq-error
           #:opendaq-error-code
           #:opendaq-error-operation
           #:with-daq-objects))

(defpackage #:opendaq.high-level
  (:nicknames #:daq #:daq.hl)
  (:use #:cl)
  (:import-from #:opendaq
                #:clear-error-info
                #:ensure-opendaq-loaded
                #:healthcheck
                #:native-library-directory
                #:opendaq-error
                #:opendaq-error-code
                #:opendaq-error-operation)
  (:shadow #:ratio
           #:numerator
           #:denominator)
  (:export #:clear-error-info
           #:ensure-opendaq-loaded
           #:healthcheck
           #:native-library-directory
           #:opendaq-error
           #:opendaq-error-code
           #:opendaq-error-operation))
