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
    ((sender opendaq::daq-base-object)
     (args opendaq::daq-base-object))
  (setf *ccoretypes-event-called* t)
  (opendaq:base-object/release-ref sender)
  (opendaq:base-object/release-ref args))

(cffi:defcallback %ccoretypes-func-call opendaq::daq-err-code
    ((params opendaq::daq-base-object)
     (result (:pointer opendaq::daq-base-object)))
  (declare (ignore params result))
  (setf *ccoretypes-function-called* t)
  0)

(cffi:defcallback %ccoretypes-proc-call opendaq::daq-err-code
    ((params opendaq::daq-base-object))
  (declare (ignore params))
  (setf *ccoretypes-procedure-called* t)
  0)

(defun %make-daq-string (value)
  (cffi:with-foreign-string (cstring value)
    (opendaq:string/create-string cstring)))

(defun %daq-string-value (string)
  (cffi:foreign-string-to-lisp (opendaq:string/get-char-ptr string)))

(test ccoretypes-base-object
  (with-daq-objects (obj)
    (setf obj (opendaq:base-object/create))
    (is (not (cffi:null-pointer-p obj))
        "ccoretypes/BaseObject returned a null object")
    (is (= 0 (opendaq:base-object/release-ref obj))
        "ccoretypes/BaseObject release refcount mismatch")
    (setf obj nil)))

(test ccoretypes-binary-data
  (with-daq-objects (binary-data)
    (setf binary-data (opendaq:binary-data/create-binary-data 10))
    (cffi:with-foreign-object (data-slot :pointer)
      (opendaq:binary-data/get-address binary-data data-slot)
      (is (not (cffi:null-pointer-p (cffi:mem-ref data-slot :pointer)))
          "ccoretypes/Binarydata returned a null data pointer"))
    (is (= 10 (opendaq:binary-data/get-size binary-data))
        "ccoretypes/Binarydata size mismatch")))

(test ccoretypes-boolean
  (with-daq-objects (boolean)
    (setf boolean (opendaq:boolean/create-boolean 0))
    (is (= 0 (opendaq:boolean/get-value boolean))
        "ccoretypes/Boolean value mismatch")))

(test ccoretypes-complex-number
  (with-daq-objects (complex-number)
    (setf complex-number (opendaq:complex-number/create-complex-number 1.0d0 2.0d0))
    (is (= 1.0d0 (opendaq:complex-number/get-real complex-number))
        "ccoretypes/ComplexNumber real mismatch")
    (is (= 2.0d0 (opendaq:complex-number/get-imaginary complex-number))
        "ccoretypes/ComplexNumber imaginary mismatch")))

(test ccoretypes-dictobject
  (with-daq-objects (dict dict-key dict-value dict-value-copy)
    (setf dict-key (%make-daq-string "key"))
    (setf dict-value (%make-daq-string "value"))
    (setf dict (opendaq:dict/create-dict))
    (opendaq:dict/set dict dict-key dict-value)
    (is (= 1 (opendaq:dict/get-count dict))
        "ccoretypes/Dictobject count mismatch")
    (setf dict-value-copy (opendaq:dict/get dict dict-key))
    (is (string= "value" (%daq-string-value dict-value-copy))
        "ccoretypes/Dictobject value mismatch")))

(test ccoretypes-enumerations
  (with-daq-objects (enumerators enum-one enum-two enum-one-name enum-two-name enum-type-name enum-type enum-value)
    (setf enumerators (opendaq:dict/create-dict))
    (setf enum-one (opendaq:integer/create-integer 1))
    (setf enum-two (opendaq:integer/create-integer 2))
    (setf enum-one-name (%make-daq-string "One"))
    (setf enum-two-name (%make-daq-string "Two"))
    (setf enum-type-name (%make-daq-string "MyEnum"))
    (opendaq:dict/set enumerators enum-one-name enum-one)
    (opendaq:dict/set enumerators enum-two-name enum-two)
    (setf enum-type
          (opendaq:enumeration-type/create-enumeration-type-with-values
           enum-type-name
           enumerators))
    (is (= 2 (opendaq:enumeration-type/get-count enum-type))
        "ccoretypes/Enumerations count mismatch")
    (setf enum-value (opendaq:enumeration/create-enumeration-with-type enum-type enum-two-name))
    (is (= 2 (opendaq:enumeration/get-int-value enum-value))
        "ccoretypes/Enumerations value mismatch")))

(test ccoretypes-event
  (with-daq-objects (event)
    (setf event (opendaq:event/create-event))
    (is (= 0 (opendaq:event/get-subscriber-count event))
        "ccoretypes/Event subscriber count mismatch")))

(test ccoretypes-event-args
  (with-daq-objects (event-name event-args event-name-copy)
    (setf event-name (%make-daq-string "test_event"))
    (setf event-args (opendaq:event-args/create-event-args 10 event-name))
    (is (= 10 (opendaq:event-args/get-event-id event-args))
        "ccoretypes/EventArgs id mismatch")
    (setf event-name-copy (opendaq:event-args/get-event-name event-args))
    (is (string= "test_event" (%daq-string-value event-name-copy))
        "ccoretypes/EventArgs name mismatch")))

(test ccoretypes-event-handler
  (with-daq-objects (event-sender event-handler-args event-handler)
    (setf *ccoretypes-event-called* nil)
    (setf event-sender (opendaq:base-object/create))
    (setf event-handler-args (opendaq:base-object/create))
    (setf event-handler (opendaq:event-handler/create-event-handler (cffi:callback %ccoretypes-on-event)))
    (opendaq:event-handler/handle-event event-handler event-sender event-handler-args)
    (is (not (null *ccoretypes-event-called*))
        "ccoretypes/EventHandler callback was not invoked")))

(test ccoretypes-float
  (with-daq-objects (float-object)
    (setf float-object (opendaq:float-object/create-float 1.0d0))
    (is (= 1.0d0 (opendaq:float-object/get-value float-object))
        "ccoretypes/Float value mismatch")))

(test ccoretypes-function
  (with-daq-objects (function-object function-params function-result)
    (setf *ccoretypes-function-called* nil)
    (setf function-object (opendaq:function/create-function (cffi:callback %ccoretypes-func-call)))
    (setf function-params (opendaq:base-object/create))
    (setf function-result (opendaq:base-object/create))
    (setf function-result (opendaq:function/call function-object function-params function-result))
    (is (not (null *ccoretypes-function-called*))
        "ccoretypes/Function callback was not invoked")))

(test ccoretypes-integer
  (with-daq-objects (integer)
    (setf integer (opendaq:integer/create-integer 1))
    (is (= 1 (opendaq:integer/get-value integer))
        "ccoretypes/Integer value mismatch")))

(test ccoretypes-listobject
  (with-daq-objects (list list-i1 list-i2 list-i3 list-front list-removed)
    (setf list (opendaq:list/create-list))
    (setf list-i1 (opendaq:integer/create-integer 1))
    (setf list-i2 (opendaq:integer/create-integer 2))
    (setf list-i3 (opendaq:integer/create-integer 3))
    (opendaq:list/push-back list list-i1)
    (opendaq:list/push-back list list-i2)
    (opendaq:list/push-back list list-i3)
    (is (= 3 (opendaq:list/get-count list))
        "ccoretypes/Listobject count mismatch")
    (setf list-front (opendaq:list/pop-front list))
    (is (= 1 (opendaq:integer/get-value list-front))
        "ccoretypes/Listobject pop-front mismatch")
    (setf list-front nil)
    (setf list-removed (opendaq:list/remove-at list 1))
    (is (= 3 (opendaq:integer/get-value list-removed))
        "ccoretypes/Listobject remove-at mismatch")
    (setf list-removed nil)
    (opendaq:list/clear list)
    (is (= 0 (opendaq:list/get-count list))
        "ccoretypes/Listobject clear mismatch")))

(test ccoretypes-procedure
  (with-daq-objects (procedure-object)
    (setf *ccoretypes-procedure-called* nil)
    (setf procedure-object (opendaq:procedure/create-procedure (cffi:callback %ccoretypes-proc-call)))
    (opendaq:procedure/dispatch procedure-object (cffi:null-pointer))
    (is (not (null *ccoretypes-procedure-called*))
        "ccoretypes/Procedure callback was not invoked")))

(test ccoretypes-ratio
  (with-daq-objects (ratio)
    (setf ratio (opendaq:ratio/create-ratio 1 2))
    (is (= 1 (opendaq:ratio/get-numerator ratio))
        "ccoretypes/Ratio numerator mismatch")
    (is (= 2 (opendaq:ratio/get-denominator ratio))
        "ccoretypes/Ratio denominator mismatch")))

(test ccoretypes-simple-type
  (with-daq-objects (simple-type)
    (setf simple-type (opendaq:simple-type/create-simple-type :daq-ct-bool))
    (is (not (cffi:null-pointer-p simple-type))
        "ccoretypes/SimpleType returned a null object")))

(test ccoretypes-stringobject
  (with-daq-objects (string-object)
    (setf string-object (%make-daq-string "Hello"))
    (is (string= "Hello" (%daq-string-value string-object))
        "ccoretypes/Stringobject value mismatch")))

(test ccoretypes-struct
  (with-daq-objects (field-names field-types field-name field-simple-type field-value struct-type-name
                                  struct-type type-manager struct-builder struct-object field-value-copy)
    (setf field-names (opendaq:list/create-list))
    (setf field-types (opendaq:list/create-list))
    (setf field-name (%make-daq-string "int"))
    (setf field-simple-type (opendaq:simple-type/create-simple-type :daq-ct-int))
    (setf field-value (opendaq:integer/create-integer 10))
    (opendaq:list/push-back field-types field-simple-type)
    (opendaq:list/push-back field-names field-name)
    (setf struct-type-name (%make-daq-string "test"))
    (setf struct-type
          (opendaq:struct-type/create-struct-type-no-defaults
           struct-type-name
           field-names
           field-types))
    (setf type-manager (opendaq:type-manager/create-type-manager))
    (opendaq:type-manager/add-type type-manager struct-type)
    (setf struct-builder (opendaq:struct-builder/create-struct-builder struct-type-name type-manager))
    (opendaq:struct-builder/set struct-builder field-name field-value)
    (setf struct-object (opendaq:struct-builder/build struct-builder))
    (setf field-value-copy (opendaq:struct/get struct-object field-name))
    (is (= 10 (opendaq:integer/get-value field-value-copy))
        "ccoretypes/Struct field mismatch")))

(test ccoretypes-type-manager
  (with-daq-objects (field-names field-types field-name field-simple-type struct-type-name struct-type type-manager)
    (setf field-names (opendaq:list/create-list))
    (setf field-types (opendaq:list/create-list))
    (setf field-name (%make-daq-string "int"))
    (setf field-simple-type (opendaq:simple-type/create-simple-type :daq-ct-int))
    (opendaq:list/push-back field-types field-simple-type)
    (opendaq:list/push-back field-names field-name)
    (setf struct-type-name (%make-daq-string "test"))
    (setf struct-type
          (opendaq:struct-type/create-struct-type-no-defaults
           struct-type-name
           field-names
           field-types))
    (setf type-manager (opendaq:type-manager/create-type-manager))
    (opendaq:type-manager/add-type type-manager struct-type)
    (finishes (opendaq:type-manager/remove-type type-manager struct-type-name))))

(test ccoretypes-version-info
  (with-daq-objects (version-info)
    (setf version-info (opendaq:version-info/create-version-info 1 2 3))
    (is (= 1 (opendaq:version-info/get-major version-info))
        "ccoretypes/VersionInfo major mismatch")
    (is (= 2 (opendaq:version-info/get-minor version-info))
        "ccoretypes/VersionInfo minor mismatch")
    (is (= 3 (opendaq:version-info/get-patch version-info))
        "ccoretypes/VersionInfo patch mismatch")))
