(asdf:defsystem "opendaq"
  :description "Common Lisp bindings for openDAQ."
  :author "Andrej Dolenc"
  :license "MIT"
  :depends-on ("cffi")
  :serial t
  :components ((:file "package")
               (:file "generated/bindings")
               (:file "loader")
               (:file "errors"))
  :in-order-to ((test-op (test-op "opendaq/tests"))))

(asdf:defsystem "opendaq/tests"
  :depends-on ("opendaq")
  :serial t
  :components ((:file "tests/smoke"))
  :perform (test-op (operation component)
             (declare (ignore operation component))
             (uiop:symbol-call :opendaq.tests :run-smoke-tests)))
