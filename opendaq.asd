(asdf:defsystem "opendaq"
  :description "Common Lisp bindings for openDAQ."
  :author "Andrej Dolenc"
  :license "MIT"
  :depends-on ("cffi" "trivial-garbage")
  :serial t
  :components ((:file "package")
               (:file "generated/bindings")
               (:file "loader")
               (:file "errors")
               (:file "utils")
               (:file "high-level-runtime")
               (:file "generated/high-level-bindings"))
  :in-order-to ((test-op (test-op "opendaq/tests"))))

(asdf:defsystem "opendaq/tests"
  :depends-on ("opendaq" "fiveam")
  :serial t
  :components ((:file "t/package")
               (:file "t/utils")
               (:file "t/compile")
               (:file "t/coretypes")
               (:file "t/coreobjects")
               (:file "t/opendaq")
               (:file "t/context")
               (:file "t/logger")
               (:file "t/device")
               (:file "t/component")
               (:file "t/streaming")
               (:file "t/server")
               (:file "t/signal")
               (:file "t/high-level")
               (:file "t/smoke"))
  :perform (test-op (operation component)
             (declare (ignore operation component))
             (uiop:symbol-call :opendaq.tests :run-test-suite)))
