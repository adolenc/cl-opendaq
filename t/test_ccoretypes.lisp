(in-package #:opendaq.tests)

;; Direct port of the subset of bindings/c/tests/ccoretypes/test_ccoretypes.cpp
;; that is currently expressible through the generated low-level Lisp bindings.
;; Tests that depend on daqBaseObject_borrowInterface remain pending until the
;; generator supports daqIntfID-by-value signatures.

(in-suite ccoretypes-suite)

(defparameter *ccoretypes-event-called* nil)
(defparameter *ccoretypes-function-called* nil)
(defparameter *ccoretypes-procedure-called* nil)

(cffi:defcallback %ccoretypes-on-event :void
    ((sender daq::daq-base-object)
     (args daq::daq-base-object))
  (setf *ccoretypes-event-called* t)
  (daq:base-object/release-ref sender)
  (daq:base-object/release-ref args))

(cffi:defcallback %ccoretypes-func-call daq::daq-err-code
    ((params daq::daq-base-object)
     (result (:pointer daq::daq-base-object)))
  (declare (ignore params result))
  (setf *ccoretypes-function-called* t)
  0)

(cffi:defcallback %ccoretypes-proc-call daq::daq-err-code
    ((params daq::daq-base-object))
  (declare (ignore params))
  (setf *ccoretypes-procedure-called* t)
  0)

(defun %daq-string-value (string)
  (cffi:foreign-string-to-lisp (daq:string/get-char-ptr string)))

(test ccoretypes-base-object
  (daq:with-daq-objects (obj)
    (setf obj (daq:base-object/create))
    (is (not (cffi:null-pointer-p obj))
        "ccoretypes/BaseObject returned a null object")
    (is (= 0 (daq:base-object/release-ref obj))
        "ccoretypes/BaseObject release refcount mismatch")
    (setf obj nil)))

(test ccoretypes-binary-data
  (daq:with-daq-objects (binary-data)
    (setf binary-data (daq:binary-data/create-binary-data 10))
    (cffi:with-foreign-object (data-slot :pointer)
      (daq:binary-data/get-address binary-data data-slot)
      (is (not (cffi:null-pointer-p (cffi:mem-ref data-slot :pointer)))
          "ccoretypes/Binarydata returned a null data pointer"))
    (is (= 10 (daq:binary-data/get-size binary-data))
        "ccoretypes/Binarydata size mismatch")))

(test ccoretypes-boolean
  (daq:with-daq-objects (boolean)
    (setf boolean (daq:boolean/create-boolean 0))
    (is (= 0 (daq:boolean/get-value boolean))
        "ccoretypes/Boolean value mismatch")))

(test ccoretypes-complex-number
  (daq:with-daq-objects (complex-number)
    (setf complex-number (daq:complex-number/create-complex-number 1.0d0 2.0d0))
    (is (= 1.0d0 (daq:complex-number/get-real complex-number))
        "ccoretypes/ComplexNumber real mismatch")
    (is (= 2.0d0 (daq:complex-number/get-imaginary complex-number))
        "ccoretypes/ComplexNumber imaginary mismatch")))

(test ccoretypes-dictobject
  (daq:with-daq-objects (dict dict-key dict-value dict-value-copy)
    (setf dict-key (daq:make-daq-string "key"))
    (setf dict-value (daq:make-daq-string "value"))
    (setf dict (daq:dict/create-dict))
    (daq:dict/set dict dict-key dict-value)
    (is (= 1 (daq:dict/get-count dict))
        "ccoretypes/Dictobject count mismatch")
    (setf dict-value-copy (daq:dict/get dict dict-key))
    (is (string= "value" (%daq-string-value dict-value-copy))
        "ccoretypes/Dictobject value mismatch")))

(test ccoretypes-enumerations
  (daq:with-daq-objects (enumerators enum-one enum-two enum-one-name enum-two-name enum-type-name enum-type enum-value)
    (setf enumerators (daq:dict/create-dict))
    (setf enum-one (daq:integer/create-integer 1))
    (setf enum-two (daq:integer/create-integer 2))
    (setf enum-one-name (daq:make-daq-string "One"))
    (setf enum-two-name (daq:make-daq-string "Two"))
    (setf enum-type-name (daq:make-daq-string "MyEnum"))
    (daq:dict/set enumerators enum-one-name enum-one)
    (daq:dict/set enumerators enum-two-name enum-two)
    (setf enum-type
          (daq:enumeration-type/create-enumeration-type-with-values
           enum-type-name
           enumerators))
    (is (= 2 (daq:enumeration-type/get-count enum-type))
        "ccoretypes/Enumerations count mismatch")
    (setf enum-value (daq:enumeration/create-enumeration-with-type enum-type enum-two-name))
    (is (= 2 (daq:enumeration/get-int-value enum-value))
        "ccoretypes/Enumerations value mismatch")))

(test ccoretypes-event
  (daq:with-daq-objects (event)
    (setf event (daq:event/create-event))
    (is (= 0 (daq:event/get-subscriber-count event))
        "ccoretypes/Event subscriber count mismatch")))

(test ccoretypes-event-args
  (daq:with-daq-objects (event-name event-args event-name-copy)
    (setf event-name (daq:make-daq-string "test_event"))
    (setf event-args (daq:event-args/create-event-args 10 event-name))
    (is (= 10 (daq:event-args/get-event-id event-args))
        "ccoretypes/EventArgs id mismatch")
    (setf event-name-copy (daq:event-args/get-event-name event-args))
    (is (string= "test_event" (%daq-string-value event-name-copy))
        "ccoretypes/EventArgs name mismatch")))

(test ccoretypes-event-handler
  (daq:with-daq-objects (event-sender event-handler-args event-handler)
    (setf *ccoretypes-event-called* nil)
    (setf event-sender (daq:base-object/create))
    (setf event-handler-args (daq:base-object/create))
    (setf event-handler (daq:event-handler/create-event-handler (cffi:callback %ccoretypes-on-event)))
    (daq:event-handler/handle-event event-handler event-sender event-handler-args)
    (is (not (null *ccoretypes-event-called*))
        "ccoretypes/EventHandler callback was not invoked")))

(test ccoretypes-float
  (daq:with-daq-objects (float-object)
    (setf float-object (daq:float-object/create-float 1.0d0))
    (is (= 1.0d0 (daq:float-object/get-value float-object))
        "ccoretypes/Float value mismatch")))

(test ccoretypes-function
  (daq:with-daq-objects (function-object function-params function-result)
    (setf *ccoretypes-function-called* nil)
    (setf function-object (daq:function/create-function (cffi:callback %ccoretypes-func-call)))
    (setf function-params (daq:base-object/create))
    (setf function-result (daq:base-object/create))
    (setf function-result (daq:function/call function-object function-params function-result))
    (is (not (null *ccoretypes-function-called*))
        "ccoretypes/Function callback was not invoked")))

(test ccoretypes-integer
  (daq:with-daq-objects (integer)
    (setf integer (daq:integer/create-integer 1))
    (is (= 1 (daq:integer/get-value integer))
        "ccoretypes/Integer value mismatch")))

(test ccoretypes-listobject
  (daq:with-daq-objects (list list-i1 list-i2 list-i3 list-front list-removed)
    (setf list (daq:list/create-list))
    (setf list-i1 (daq:integer/create-integer 1))
    (setf list-i2 (daq:integer/create-integer 2))
    (setf list-i3 (daq:integer/create-integer 3))
    (daq:list/push-back list list-i1)
    (daq:list/push-back list list-i2)
    (daq:list/push-back list list-i3)
    (is (= 3 (daq:list/get-count list))
        "ccoretypes/Listobject count mismatch")
    (setf list-front (daq:list/pop-front list))
    (is (= 1 (daq:integer/get-value list-front))
        "ccoretypes/Listobject pop-front mismatch")
    (setf list-front nil)
    (setf list-removed (daq:list/remove-at list 1))
    (is (= 3 (daq:integer/get-value list-removed))
        "ccoretypes/Listobject remove-at mismatch")
    (setf list-removed nil)
    (daq:list/clear list)
    (is (= 0 (daq:list/get-count list))
        "ccoretypes/Listobject clear mismatch")))

(test ccoretypes-procedure
  (daq:with-daq-objects (procedure-object)
    (setf *ccoretypes-procedure-called* nil)
    (setf procedure-object (daq:procedure/create-procedure (cffi:callback %ccoretypes-proc-call)))
    (daq:procedure/dispatch procedure-object (cffi:null-pointer))
    (is (not (null *ccoretypes-procedure-called*))
        "ccoretypes/Procedure callback was not invoked")))

(test ccoretypes-ratio
  (daq:with-daq-objects (ratio)
    (setf ratio (daq:ratio/create-ratio 1 2))
    (is (= 1 (daq:ratio/get-numerator ratio))
        "ccoretypes/Ratio numerator mismatch")
    (is (= 2 (daq:ratio/get-denominator ratio))
        "ccoretypes/Ratio denominator mismatch")))

(test ccoretypes-simple-type
  (daq:with-daq-objects (simple-type)
    (setf simple-type (daq:simple-type/create-simple-type :daq-ct-bool))
    (is (not (cffi:null-pointer-p simple-type))
        "ccoretypes/SimpleType returned a null object")))

(test ccoretypes-stringobject
  (daq:with-daq-objects (string-object)
    (setf string-object (daq:make-daq-string "Hello"))
    (is (string= "Hello" (%daq-string-value string-object))
        "ccoretypes/Stringobject value mismatch")))

(test ccoretypes-struct
  (daq:with-daq-objects (field-names field-types field-name field-simple-type field-value struct-type-name
                         struct-type type-manager struct-builder struct-object field-value-copy)
    (setf field-names (daq:list/create-list))
    (setf field-types (daq:list/create-list))
    (setf field-name (daq:make-daq-string "int"))
    (setf field-simple-type (daq:simple-type/create-simple-type :daq-ct-int))
    (setf field-value (daq:integer/create-integer 10))
    (daq:list/push-back field-types field-simple-type)
    (daq:list/push-back field-names field-name)
    (setf struct-type-name (daq:make-daq-string "test"))
    (setf struct-type
          (daq:struct-type/create-struct-type-no-defaults
           struct-type-name
           field-names
           field-types))
    (setf type-manager (daq:type-manager/create-type-manager))
    (daq:type-manager/add-type type-manager struct-type)
    (setf struct-builder (daq:struct-builder/create-struct-builder struct-type-name type-manager))
    (daq:struct-builder/set struct-builder field-name field-value)
    (setf struct-object (daq:struct-builder/build struct-builder))
    (setf field-value-copy (daq:struct/get struct-object field-name))
    (is (= 10 (daq:integer/get-value field-value-copy))
        "ccoretypes/Struct field mismatch")))

(test ccoretypes-type-manager
  (daq:with-daq-objects (field-names field-types field-name field-simple-type struct-type-name struct-type type-manager)
    (setf field-names (daq:list/create-list))
    (setf field-types (daq:list/create-list))
    (setf field-name (daq:make-daq-string "int"))
    (setf field-simple-type (daq:simple-type/create-simple-type :daq-ct-int))
    (daq:list/push-back field-types field-simple-type)
    (daq:list/push-back field-names field-name)
    (setf struct-type-name (daq:make-daq-string "test"))
    (setf struct-type
          (daq:struct-type/create-struct-type-no-defaults
           struct-type-name
           field-names
           field-types))
    (setf type-manager (daq:type-manager/create-type-manager))
    (daq:type-manager/add-type type-manager struct-type)
    (finishes (daq:type-manager/remove-type type-manager struct-type-name))))

(test ccoretypes-version-info
  (daq:with-daq-objects (version-info)
    (setf version-info (daq:version-info/create-version-info 1 2 3))
    (is (= 1 (daq:version-info/get-major version-info))
        "ccoretypes/VersionInfo major mismatch")
    (is (= 2 (daq:version-info/get-minor version-info))
        "ccoretypes/VersionInfo minor mismatch")
    (is (= 3 (daq:version-info/get-patch version-info))
        "ccoretypes/VersionInfo patch mismatch")))
