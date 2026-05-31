(asdf:defsystem "opendaq"
  :description "Common Lisp bindings for openDAQ."
  :author "Andrej Dolenc"
  :license "MIT"
  :depends-on ("cffi")
  :serial t
  :components ((:file "package")
               (:file "generated/bindings")
               (:file "loader")
               (:file "errors")
               (:file "utils"))
  :in-order-to ((test-op (test-op "opendaq/tests"))))

(asdf:defsystem "opendaq/tests"
  :depends-on ("opendaq" "fiveam")
  :serial t
  :components ((:file "t/package")
               (:file "t/utils")
               (:file "t/compile")
               (:file "t/coretypes")
               (:file "t/smoke"))
  :perform (test-op (operation component)
             (declare (ignore operation component))
             (uiop:symbol-call :opendaq.tests :run-test-suite)))
