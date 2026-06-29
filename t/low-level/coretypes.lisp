(in-package #:opendaq.tests)

;; Direct port of the currently supported upstream coretypes coverage
;; that is expressible through the generated low-level Lisp bindings.
;; Tests that depend on daqBaseObject_borrowInterface remain pending until the
;; generator supports daqIntfID-by-value signatures.

(in-suite low-level-coretypes-suite)

(defparameter *coretypes-event-called* nil)
(defparameter *coretypes-function-called* nil)
(defparameter *coretypes-procedure-called* nil)

(cffi:defcallback %coretypes-on-event :void
    ((sender opendaq.low-level::daq-base-object)
     (args opendaq.low-level::daq-base-object))
  (setf *coretypes-event-called* t)
  (opendaq.low-level:base-object/release-ref sender)
  (opendaq.low-level:base-object/release-ref args))

(cffi:defcallback %coretypes-func-call opendaq.low-level::daq-err-code
    ((params opendaq.low-level::daq-base-object)
     (result (:pointer opendaq.low-level::daq-base-object)))
  (declare (ignore params result))
  (setf *coretypes-function-called* t)
  0)

(cffi:defcallback %coretypes-proc-call opendaq.low-level::daq-err-code
    ((params opendaq.low-level::daq-base-object))
  (declare (ignore params))
  (setf *coretypes-procedure-called* t)
  0)

(test coretypes-base-object
  (opendaq.low-level:with-daq-objects (obj)
    (setf obj (opendaq.low-level:base-object/create))
    (is (not (cffi:null-pointer-p obj)) "coretypes/BaseObject returned a null object")
    (is (= 0 (opendaq.low-level:base-object/release-ref obj)) "coretypes/BaseObject release refcount mismatch")
    (setf obj nil)))

(test coretypes-binary-data
  (opendaq.low-level:with-daq-objects (binary-data)
    (setf binary-data (opendaq.low-level:binary-data/create-binary-data 10))
    (cffi:with-foreign-object (data-slot :pointer)
      (opendaq.low-level:binary-data/get-address binary-data data-slot)
      (is (not (cffi:null-pointer-p (cffi:mem-ref data-slot :pointer))) "coretypes/Binarydata returned a null data pointer"))
    (is (= 10 (opendaq.low-level:binary-data/get-size binary-data)) "coretypes/Binarydata size mismatch")))

(test coretypes-boolean
  (opendaq.low-level:with-daq-objects (boolean)
    (setf boolean (opendaq.low-level:boolean/create-boolean 0))
    (is (= 0 (opendaq.low-level:boolean/get-value boolean)) "coretypes/Boolean value mismatch")))

(test coretypes-complex-number
  (opendaq.low-level:with-daq-objects (complex-number)
    (setf complex-number (opendaq.low-level:complex-number/create-complex-number 1.0d0 2.0d0))
    (is (= 1.0d0 (opendaq.low-level:complex-number/get-real complex-number)) "coretypes/ComplexNumber real mismatch")
    (is (= 2.0d0 (opendaq.low-level:complex-number/get-imaginary complex-number)) "coretypes/ComplexNumber imaginary mismatch")))

(test coretypes-dictobject
  (opendaq.low-level:with-daq-objects (dict dict-key dict-value dict-value-copy)
    (setf dict-key (opendaq.low-level:make-daq-string "key"))
    (setf dict-value (opendaq.low-level:make-daq-string "value"))
    (setf dict (opendaq.low-level:dict/create-dict))
    (opendaq.low-level:dict/set dict dict-key dict-value)
    (is (= 1 (opendaq.low-level:dict/get-count dict)) "coretypes/Dictobject count mismatch")
    (setf dict-value-copy (opendaq.low-level:dict/get dict dict-key))
    (is (string= "value" (%daq-string-value dict-value-copy)) "coretypes/Dictobject value mismatch")))

(test coretypes-enumerations
  (opendaq.low-level:with-daq-objects (enumerators enum-one enum-two enum-one-name enum-two-name enum-type-name enum-type enum-value)
    (setf enumerators (opendaq.low-level:dict/create-dict))
    (setf enum-one (opendaq.low-level:integer/create-integer 1))
    (setf enum-two (opendaq.low-level:integer/create-integer 2))
    (setf enum-one-name (opendaq.low-level:make-daq-string "One"))
    (setf enum-two-name (opendaq.low-level:make-daq-string "Two"))
    (setf enum-type-name (opendaq.low-level:make-daq-string "MyEnum"))
    (opendaq.low-level:dict/set enumerators enum-one-name enum-one)
    (opendaq.low-level:dict/set enumerators enum-two-name enum-two)
    (setf enum-type
          (opendaq.low-level:enumeration-type/create-enumeration-type-with-values
           enum-type-name
           enumerators))
    (is (= 2 (opendaq.low-level:enumeration-type/get-count enum-type)) "coretypes/Enumerations count mismatch")
    (setf enum-value (opendaq.low-level:enumeration/create-enumeration-with-type enum-type enum-two-name))
    (is (= 2 (opendaq.low-level:enumeration/get-int-value enum-value)) "coretypes/Enumerations value mismatch")))

(test coretypes-event
  (opendaq.low-level:with-daq-objects (event)
    (setf event (opendaq.low-level:event/create-event))
    (is (= 0 (opendaq.low-level:event/get-subscriber-count event)) "coretypes/Event subscriber count mismatch")))

(test coretypes-event-args
  (opendaq.low-level:with-daq-objects (event-name event-args event-name-copy)
    (setf event-name (opendaq.low-level:make-daq-string "test_event"))
    (setf event-args (opendaq.low-level:event-args/create-event-args 10 event-name))
    (is (= 10 (opendaq.low-level:event-args/get-event-id event-args)) "coretypes/EventArgs id mismatch")
    (setf event-name-copy (opendaq.low-level:event-args/get-event-name event-args))
    (is (string= "test_event" (%daq-string-value event-name-copy)) "coretypes/EventArgs name mismatch")))

(test coretypes-event-handler
  (opendaq.low-level:with-daq-objects (event-sender event-handler-args event-handler)
    (setf *coretypes-event-called* nil)
    (setf event-sender (opendaq.low-level:base-object/create))
    (setf event-handler-args (opendaq.low-level:base-object/create))
    (setf event-handler (opendaq.low-level:event-handler/create-event-handler (cffi:callback %coretypes-on-event)))
    (opendaq.low-level:event-handler/handle-event event-handler event-sender event-handler-args)
    (is (not (null *coretypes-event-called*)) "coretypes/EventHandler callback was not invoked")))

(test coretypes-float
  (opendaq.low-level:with-daq-objects (float-object)
    (setf float-object (opendaq.low-level:float-object/create-float 1.0d0))
    (is (= 1.0d0 (opendaq.low-level:float-object/get-value float-object)) "coretypes/Float value mismatch")))

(test coretypes-function
  (opendaq.low-level:with-daq-objects (function-object function-params function-result)
    (setf *coretypes-function-called* nil)
    (setf function-object (opendaq.low-level:function/create-function (cffi:callback %coretypes-func-call)))
    (setf function-params (opendaq.low-level:base-object/create))
    (setf function-result (opendaq.low-level:base-object/create))
    (setf function-result (opendaq.low-level:function/call function-object function-params function-result))
    (is (not (null *coretypes-function-called*)) "coretypes/Function callback was not invoked")))

(test coretypes-integer
  (opendaq.low-level:with-daq-objects (integer)
    (setf integer (opendaq.low-level:integer/create-integer 1))
    (is (= 1 (opendaq.low-level:integer/get-value integer)) "coretypes/Integer value mismatch")))

(test coretypes-listobject
  (opendaq.low-level:with-daq-objects (list list-i1 list-i2 list-i3 list-front list-removed)
    (setf list (opendaq.low-level:list/create-list))
    (setf list-i1 (opendaq.low-level:integer/create-integer 1))
    (setf list-i2 (opendaq.low-level:integer/create-integer 2))
    (setf list-i3 (opendaq.low-level:integer/create-integer 3))
    (opendaq.low-level:list/push-back list list-i1)
    (opendaq.low-level:list/push-back list list-i2)
    (opendaq.low-level:list/push-back list list-i3)
    (is (= 3 (opendaq.low-level:list/get-count list)) "coretypes/Listobject count mismatch")
    (setf list-front (opendaq.low-level:list/pop-front list))
    (is (= 1 (opendaq.low-level:integer/get-value list-front)) "coretypes/Listobject pop-front mismatch")
    (setf list-front nil)
    (setf list-removed (opendaq.low-level:list/remove-at list 1))
    (is (= 3 (opendaq.low-level:integer/get-value list-removed)) "coretypes/Listobject remove-at mismatch")
    (setf list-removed nil)
    (opendaq.low-level:list/clear list)
    (is (= 0 (opendaq.low-level:list/get-count list)) "coretypes/Listobject clear mismatch")))

(test coretypes-procedure
  (opendaq.low-level:with-daq-objects (procedure-object)
    (setf *coretypes-procedure-called* nil)
    (setf procedure-object (opendaq.low-level:procedure/create-procedure (cffi:callback %coretypes-proc-call)))
    (opendaq.low-level:procedure/dispatch procedure-object (cffi:null-pointer))
    (is (not (null *coretypes-procedure-called*)) "coretypes/Procedure callback was not invoked")))

(test coretypes-ratio
  (opendaq.low-level:with-daq-objects (ratio)
    (setf ratio (opendaq.low-level:ratio/create-ratio 1 2))
    (is (= 1 (opendaq.low-level:ratio/get-numerator ratio)) "coretypes/Ratio numerator mismatch")
    (is (= 2 (opendaq.low-level:ratio/get-denominator ratio)) "coretypes/Ratio denominator mismatch")))

(test coretypes-simple-type
  (opendaq.low-level:with-daq-objects (simple-type)
    (setf simple-type (opendaq.low-level:simple-type/create-simple-type :bool))
    (is (not (cffi:null-pointer-p simple-type)) "coretypes/SimpleType returned a null object")))

(test coretypes-stringobject
  (opendaq.low-level:with-daq-objects (string-object)
    (setf string-object (opendaq.low-level:make-daq-string "Hello"))
    (is (string= "Hello" (%daq-string-value string-object)) "coretypes/Stringobject value mismatch")))

(test coretypes-struct
  (opendaq.low-level:with-daq-objects (field-names field-types field-name field-simple-type field-value struct-type-name
                         struct-type type-manager struct-builder struct-object field-value-copy)
    (setf field-names (opendaq.low-level:list/create-list))
    (setf field-types (opendaq.low-level:list/create-list))
    (setf field-name (opendaq.low-level:make-daq-string "int"))
    (setf field-simple-type (opendaq.low-level:simple-type/create-simple-type :int))
    (setf field-value (opendaq.low-level:integer/create-integer 10))
    (opendaq.low-level:list/push-back field-types field-simple-type)
    (opendaq.low-level:list/push-back field-names field-name)
    (setf struct-type-name (opendaq.low-level:make-daq-string "test"))
    (setf struct-type
          (opendaq.low-level:struct-type/create-struct-type-no-defaults
           struct-type-name
           field-names
           field-types))
    (setf type-manager (opendaq.low-level:type-manager/create-type-manager))
    (opendaq.low-level:type-manager/add-type type-manager struct-type)
    (setf struct-builder (opendaq.low-level:struct-builder/create-struct-builder struct-type-name type-manager))
    (opendaq.low-level:struct-builder/set struct-builder field-name field-value)
    (setf struct-object (opendaq.low-level:struct-builder/build struct-builder))
    (setf field-value-copy (opendaq.low-level:struct/get struct-object field-name))
    (is (= 10 (opendaq.low-level:integer/get-value field-value-copy)) "coretypes/Struct field mismatch")))

(test coretypes-type-manager
  (opendaq.low-level:with-daq-objects (field-names field-types field-name field-simple-type struct-type-name struct-type type-manager)
    (setf field-names (opendaq.low-level:list/create-list))
    (setf field-types (opendaq.low-level:list/create-list))
    (setf field-name (opendaq.low-level:make-daq-string "int"))
    (setf field-simple-type (opendaq.low-level:simple-type/create-simple-type :int))
    (opendaq.low-level:list/push-back field-types field-simple-type)
    (opendaq.low-level:list/push-back field-names field-name)
    (setf struct-type-name (opendaq.low-level:make-daq-string "test"))
    (setf struct-type
          (opendaq.low-level:struct-type/create-struct-type-no-defaults
           struct-type-name
           field-names
           field-types))
    (setf type-manager (opendaq.low-level:type-manager/create-type-manager))
    (opendaq.low-level:type-manager/add-type type-manager struct-type)
    (finishes (opendaq.low-level:type-manager/remove-type type-manager struct-type-name))))

(test coretypes-version-info
  (opendaq.low-level:with-daq-objects (version-info)
    (setf version-info (opendaq.low-level:version-info/create-version-info 1 2 3))
    (is (= 1 (opendaq.low-level:version-info/get-major version-info)) "coretypes/VersionInfo major mismatch")
    (is (= 2 (opendaq.low-level:version-info/get-minor version-info)) "coretypes/VersionInfo minor mismatch")
    (is (= 3 (opendaq.low-level:version-info/get-patch version-info)) "coretypes/VersionInfo patch mismatch")))
