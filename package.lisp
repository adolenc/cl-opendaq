(defpackage #:opendaq.low-level
  (:use #:cl)
  (:intern #:clear-error-info
           #:ensure-opendaq-loaded
           #:healthcheck
           #:install-native-libraries
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
                #:healthcheck
                #:install-native-libraries
                #:native-library-directory
                #:opendaq-error
                #:opendaq-error-code
                #:opendaq-error-message
                #:opendaq-error-operation)
  (:shadow #:numerator
           #:denominator
           #:read
           #:typep)
  (:export #:as
           #:unbox
           #:typep
           #:with-batch-property-updates
           #:component-type
           #:domain-time-converter
           #:domain-tick->timestamp
           #:healthcheck
           #:install-native-libraries
           #:native-library-directory
           #:opendaq-error
           #:opendaq-error-code
           #:opendaq-error-message
           #:opendaq-error-operation))
