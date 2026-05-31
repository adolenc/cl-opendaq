(defpackage #:opendaq
  (:use #:cl)
  (:export #:ensure-opendaq-loaded
           #:native-library-directory
           #:opendaq-error
           #:opendaq-error-code
           #:opendaq-error-operation))

(defpackage #:opendaq.tests
  (:use #:cl)
  (:export #:run-smoke-tests))
